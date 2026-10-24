using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Media;

namespace OmarchyBar;

public sealed class ShellFile
{
    public int Version { get; set; }
    public BarConfig Bar { get; set; } = new();
}

public sealed class BarConfig
{
    public string Position { get; set; } = "top";
    public int Height { get; set; } = 34;
    public bool Transparent { get; set; } = true;
    public bool Visible { get; set; } = true;
    public string CenterAnchor { get; set; } = "";
    public BarLayout Layout { get; set; } = new();
}

public sealed class BarLayout
{
    public List<WidgetConfig> Left { get; set; } = new();
    public List<WidgetConfig> Center { get; set; } = new();
    public List<WidgetConfig> Right { get; set; } = new();
}

public sealed class WidgetConfig
{
    public string Id { get; set; } = "";
    public string? Format { get; set; }
}

public sealed class ThemeFile
{
    public string Background { get; set; } = "#1d2021";
    public string Foreground { get; set; } = "#ebdbb2";
    public string Accent { get; set; } = "#fabd2f";
    public string Urgent { get; set; } = "#fb4934";
    public string Muted { get; set; } = "#928374";
    public string FontFamily { get; set; } = "Segoe UI Variable";
    public double FontSize { get; set; } = 13;
}

public sealed class ThemeBrushes
{
    public required SolidColorBrush Background { get; init; }
    public required SolidColorBrush Foreground { get; init; }
    public required SolidColorBrush Accent { get; init; }
    public required SolidColorBrush Urgent { get; init; }
    public required SolidColorBrush Muted { get; init; }
    public required FontFamily Font { get; init; }
    public required double FontSize { get; init; }

    public static ThemeBrushes Load(ThemeFile theme)
    {
        var background = Freeze(Parse(theme.Background));
        var foreground = Freeze(Parse(theme.Foreground));
        var accent = Freeze(Parse(theme.Accent));
        var urgent = Freeze(Parse(theme.Urgent));
        var muted = Freeze(Parse(theme.Muted));
        return new ThemeBrushes
        {
            Background = background,
            Foreground = foreground,
            Accent = accent,
            Urgent = urgent,
            Muted = muted,
            Font = new FontFamily(theme.FontFamily + ", Segoe UI"),
            FontSize = theme.FontSize,
        };
    }

    private static SolidColorBrush Freeze(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private static Color Parse(string hex)
    {
        hex = hex.Trim().TrimStart('#');
        if (hex.Length != 6)
            return Color.FromRgb(0x1d, 0x20, 0x21);
        return Color.FromRgb(
            Convert.ToByte(hex[..2], 16),
            Convert.ToByte(hex[2..4], 16),
            Convert.ToByte(hex[4..6], 16));
    }
}

public static class RepoConfig
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        ReadCommentHandling = JsonCommentHandling.Skip,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static string FindRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "config", "shell.json")))
                return dir.FullName;
            dir = dir.Parent;
        }

        dir = new DirectoryInfo(Environment.CurrentDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "config", "shell.json")))
                return dir.FullName;
            dir = dir.Parent;
        }

        throw new DirectoryNotFoundException("config\\shell.json was not found above the bar executable.");
    }

    public static ShellFile LoadShell(string root) =>
        JsonSerializer.Deserialize<ShellFile>(File.ReadAllText(Path.Combine(root, "config", "shell.json")), JsonOptions)
        ?? new ShellFile();

    public static ThemeFile LoadTheme(string root) =>
        JsonSerializer.Deserialize<ThemeFile>(File.ReadAllText(Path.Combine(root, "config", "theme.json")), JsonOptions)
        ?? new ThemeFile();
}
