using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace OmarchyBar;

public partial class MainWindow : Window
{
    private readonly string _root;
    private readonly ThemeBrushes _theme;
    private ShellFile _shell;
    private readonly string? _komorebic;
    private KomorebiClient? _client;
    private FileSystemWatcher? _watcher;
    private int _reloadGeneration;
    private StackPanel? _workspaces;
    private TextBlock? _title;
    private TextBlock? _clock;
    private string _clockFormat = "HH:mm";
    private TextBlock? _cpu;
    private TextBlock? _memory;
    private TextBlock? _volume;
    private TextBlock? _network;
    private TextBlock? _battery;
    private TextBlock? _power;
    public Brush ThemeBackground => _theme.Background;

    public MainWindow()
    {
        InitializeComponent();
        _root = RepoConfig.FindRoot();
        _shell = RepoConfig.LoadShell(_root);
        _theme = ThemeBrushes.Load(RepoConfig.LoadTheme(_root));
        _komorebic = FindKomorebic();
        FontFamily = _theme.Font;
        FontSize = _theme.FontSize;
        Height = _shell.Bar.Height;
        BuildWidgets();
        Loaded += OnLoaded;
        Closed += (_, _) =>
        {
            _watcher?.Dispose();
            _client?.Dispose();
        };
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        PlaceOnPrimaryMonitor();
        if (!_shell.Bar.Transparent)
            Background = _theme.Background;
        WindowChrome.Apply(this, _shell.Bar.Transparent);

        WatchShell();
        ApplyVisibility();

        if (_komorebic is not null)
        {
            _client = new KomorebiClient(_komorebic);
            _client.WorkspacesChanged += chips => Dispatcher.Invoke(() => ShowWorkspaces(chips));
            _client.TitleChanged += title => Dispatcher.Invoke(() => SetTitle(title));
            _client.Start();
        }

        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        timer.Tick += (_, _) => RefreshStats();
        timer.Start();
        RefreshStats();
        SetTitle(ForegroundTitle());
    }

    private void BuildWidgets()
    {
        LeftPanel.Children.Clear();
        CenterPanel.Children.Clear();
        RightPanel.Children.Clear();
        AddWidgets(LeftPanel, _shell.Bar.Layout.Left);
        AddWidgets(CenterPanel, _shell.Bar.Layout.Center);
        AddWidgets(RightPanel, _shell.Bar.Layout.Right);
    }

    private void AddWidgets(StackPanel panel, IReadOnlyList<WidgetConfig> widgets)
    {
        foreach (var widget in widgets)
        {
            switch (widget.Id)
            {
                case "omarchy.power":
                    var powerButton = MakeButton(ReadSystemEnabled() ? "On" : "Off", _theme.Accent, ToggleSystem);
                    _power = powerButton.Content as TextBlock;
                    panel.Children.Add(powerButton);
                    break;
                case "omarchy.menu":
                    panel.Children.Add(MakeButton("\u2630", _theme.Foreground, LaunchFlow));
                    break;
                case "omarchy.workspaces":
                    _workspaces = new StackPanel { Orientation = Orientation.Horizontal };
                    panel.Children.Add(_workspaces);
                    break;
                case "omarchy.window-title":
                    _title = MakeText("", _theme.Foreground, 420);
                    panel.Children.Add(_title);
                    break;
                case "omarchy.clock":
                    _clockFormat = string.IsNullOrWhiteSpace(widget.Format) ? "HH:mm" : widget.Format;
                    _clock = MakeText(DateTime.Now.ToString(_clockFormat), _theme.Foreground, 120);
                    panel.Children.Add(_clock);
                    break;
                case "omarchy.cpu":
                    _cpu = MakeStat();
                    panel.Children.Add(_cpu);
                    break;
                case "omarchy.memory":
                    _memory = MakeStat();
                    panel.Children.Add(_memory);
                    break;
                case "omarchy.audio":
                    _volume = MakeStat();
                    panel.Children.Add(_volume);
                    break;
                case "omarchy.network":
                    _network = MakeStat();
                    panel.Children.Add(_network);
                    break;
                case "omarchy.battery":
                    _battery = MakeStat();
                    panel.Children.Add(_battery);
                    break;
            }
        }
    }

    private Button MakeButton(string text, Brush foreground, Action click)
    {
        var button = new Button
        {
            Content = new TextBlock
            {
                Text = text,
                Foreground = foreground,
                FontFamily = _theme.Font,
                FontSize = _theme.FontSize,
            },
            Style = BarButtonStyle,
        };
        button.Click += (_, _) => click();
        return button;
    }

    private static readonly Style BarButtonStyle = CreateButtonStyle();

    private static Style CreateButtonStyle()
    {
        var style = new Style(typeof(Button));
        style.Setters.Add(new Setter(Control.BackgroundProperty, Brushes.Transparent));
        style.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(0)));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(8, 0, 8, 0)));
        style.Setters.Add(new Setter(UIElement.FocusableProperty, false));
        style.Setters.Add(new Setter(FrameworkElement.CursorProperty, System.Windows.Input.Cursors.Hand));

        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
        border.SetValue(Border.PaddingProperty, new TemplateBindingExtension(Control.PaddingProperty));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(presenter);

        var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        style.Setters.Add(new Setter(Control.TemplateProperty, template));
        style.Seal();
        return style;
    }

    private TextBlock MakeText(string text, Brush foreground, double maxWidth) => new()
    {
        Text = text,
        Foreground = foreground,
        FontFamily = _theme.Font,
        FontSize = _theme.FontSize,
        VerticalAlignment = VerticalAlignment.Center,
        TextTrimming = TextTrimming.CharacterEllipsis,
        MaxWidth = maxWidth,
        Margin = new Thickness(8, 0, 8, 0),
    };

    private TextBlock MakeStat() => MakeText("--", _theme.Muted, 90);

    private void ShowWorkspaces(IReadOnlyList<WorkspaceChip> chips)
    {
        if (_workspaces is null)
            return;
        _workspaces.Children.Clear();
        foreach (var chip in chips)
        {
            var index = chip.Index;
            var labelName = chip.Name;
            var foreground = chip.Focused ? _theme.Accent : _theme.Muted;
            var button = MakeButton(labelName, foreground, () => FocusWorkspaceChip(labelName, index));
            if (button.Content is TextBlock label)
                label.FontWeight = chip.Focused ? FontWeights.SemiBold : FontWeights.Normal;
            _workspaces.Children.Add(button);
        }
    }

    private void SetTitle(string title)
    {
        if (_title is null || string.IsNullOrWhiteSpace(title))
            return;
        _title.Text = title;
    }

    private void RefreshStats()
    {
        if (_clock is not null)
        {
            try
            {
                _clock.Text = DateTime.Now.ToString(_clockFormat);
            }
            catch (FormatException)
            {
                _clock.Text = DateTime.Now.ToString("HH:mm");
            }
        }
        if (_cpu is not null) _cpu.Text = SystemStats.Cpu();
        if (_memory is not null) _memory.Text = SystemStats.Memory();
        if (_volume is not null) _volume.Text = SystemStats.Volume();
        if (_network is not null) _network.Text = SystemStats.Network();
        if (_battery is not null) _battery.Text = SystemStats.Battery();
        if (_power is not null)
        {
            var enabled = ReadSystemEnabled();
            _power.Text = enabled ? "On" : "Off";
            _power.Foreground = enabled ? _theme.Accent : _theme.Muted;
        }
        if (string.IsNullOrWhiteSpace(_title?.Text))
            SetTitle(ForegroundTitle());
    }

    private void PlaceOnPrimaryMonitor()
    {
        if (!WindowChrome.TryGetPrimaryMonitor(out var rect))
            return;
        var source = PresentationSource.FromVisual(this);
        var transform = source?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var topLeft = transform.Transform(new Point(rect.Left, rect.Top));
        var bottomRight = transform.Transform(new Point(rect.Right, rect.Bottom));
        Left = topLeft.X;
        Top = topLeft.Y;
        Width = Math.Max(100, bottomRight.X - topLeft.X);
        Height = _shell.Bar.Height;
    }

    private void WatchShell()
    {
        var directory = Path.Combine(_root, "config");
        _watcher = new FileSystemWatcher(directory, "shell.json")
        {
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName,
        };
        _watcher.Changed += (_, _) => ScheduleReload();
        _watcher.Created += (_, _) => ScheduleReload();
        _watcher.Renamed += (_, _) => ScheduleReload();
        _watcher.EnableRaisingEvents = true;
    }

    private void ScheduleReload()
    {
        var token = Interlocked.Increment(ref _reloadGeneration);
        _ = Task.Run(async () =>
        {
            await Task.Delay(200);
            if (token != _reloadGeneration)
                return;
            await Dispatcher.InvokeAsync(ApplyVisibility);
        });
    }

    private void ApplyVisibility()
    {
        try
        {
            _shell = RepoConfig.LoadShell(_root);
        }
        catch (IOException)
        {
            return;
        }

        if (_shell.Bar.Visible)
        {
            if (!IsVisible)
                Show();
            PlaceOnPrimaryMonitor();
            SetOffset(_shell.Bar.Height);
        }
        else
        {
            SetOffset(0);
            Hide();
        }
    }

    private void SetOffset(int top)
    {
        if (_komorebic is null)
            return;
        try
        {
            Process.Start(new ProcessStartInfo(_komorebic, $"monitor-work-area-offset 0 0 {top} 0 {top}")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            Process.Start(new ProcessStartInfo(_komorebic, "monitor-work-area-offset 1 0 0 0 0")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            });
        }
        catch (Exception ex)
        {
            Debug.WriteLine(ex);
        }
    }

    private void FocusWorkspaceChip(string name, int index)
    {
        if (name.Length == 1 && name[0] >= '1' && name[0] <= '9')
        {
            var script = Path.Combine(_root, "cli", "omarchy.ps1");
            if (File.Exists(script))
            {
                try
                {
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = "powershell.exe",
                        Arguments = $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\" workspace {name}",
                        UseShellExecute = false,
                        CreateNoWindow = true,
                    });
                    return;
                }
                catch (Exception ex)
                {
                    Debug.WriteLine(ex);
                }
            }
        }
        _client?.FocusWorkspace(index);
    }

    private void ToggleSystem()
    {
        var script = Path.Combine(_root, "cli", "omarchy.ps1");
        if (!File.Exists(script))
            return;
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\" system toggle",
                UseShellExecute = false,
                CreateNoWindow = true,
            });
        }
        catch (Exception ex)
        {
            Debug.WriteLine(ex);
        }
    }

    private static bool ReadSystemEnabled()
    {
        var path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "omarchy",
            "system-enabled");
        if (!File.Exists(path))
            return true;
        try
        {
            return !File.ReadAllText(path).Trim().Equals("off", StringComparison.OrdinalIgnoreCase);
        }
        catch (IOException)
        {
            return true;
        }
    }

    private static void LaunchFlow()
    {
        var path = FindFlowLauncher();
        if (path is null)
            return;
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    private static string? FindFlowLauncher()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var candidates = new[]
        {
            Path.Combine(local, "FlowLauncher", "Flow.Launcher.exe"),
            Path.Combine(local, "FlowLauncher", "app", "Flow.Launcher.exe"),
            Path.Combine(programFiles, "Flow Launcher", "Flow.Launcher.exe"),
        };
        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
                return candidate;
        }

        var root = Path.Combine(local, "FlowLauncher");
        if (Directory.Exists(root))
        {
            var versioned = Directory.GetDirectories(root, "app-*")
                .Select(dir => Path.Combine(dir, "Flow.Launcher.exe"))
                .FirstOrDefault(File.Exists);
            if (versioned is not null)
                return versioned;
        }

        return FindOnPath("Flow.Launcher.exe");
    }

    private static string? FindKomorebic() => FindOnPath("komorebic.exe")
        ?? Existing(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "komorebi", "komorebic.exe"))
        ?? Existing(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WinGet", "Links", "komorebic.exe"));

    private static string? FindOnPath(string name)
    {
        var path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(path))
            return null;
        foreach (var dir in path.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(dir.Trim().Trim('"'), name);
            if (File.Exists(candidate))
                return candidate;
        }
        return null;
    }

    private static string? Existing(string path) => File.Exists(path) ? path : null;

    private static string ForegroundTitle()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero)
            return "";
        var buffer = new System.Text.StringBuilder(512);
        var length = GetWindowText(hwnd, buffer, buffer.Capacity);
        return length <= 0 ? "" : buffer.ToString(0, length);
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hwnd, System.Text.StringBuilder buffer, int maxCount);
}
