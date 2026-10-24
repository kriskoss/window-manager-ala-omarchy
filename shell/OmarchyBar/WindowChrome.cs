using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace OmarchyBar;

internal static class WindowChrome
{
    private const int GwlExStyle = -20;
    private const int WsExToolWindow = 0x00000080;
    private const int WsExNoActivate = 0x08000000;
    private const int WsExAppWindow = 0x00040000;
    private const int WmMouseActivate = 0x0021;
    private const int MaNoActivate = 3;
    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int DwmwaWindowCornerPreference = 33;
    private const int DwmwaSystemBackdropType = 38;
    private const int DwmwcpDoNotRound = 1;
    private const int DwmSbtTransientWindow = 3;
    private const uint MonitorDefaultToPrimary = 1;

    public static void Apply(Window window, bool acrylic)
    {
        var hwnd = new WindowInteropHelper(window).EnsureHandle();
        var ex = GetWindowLong(hwnd, GwlExStyle);
        ex |= WsExToolWindow | WsExNoActivate;
        ex &= ~WsExAppWindow;
        SetWindowLong(hwnd, GwlExStyle, ex);

        var source = HwndSource.FromHwnd(hwnd);
        if (source is not null)
        {
            source.AddHook(MouseActivate);
            source.CompositionTarget.BackgroundColor = System.Windows.Media.Color.FromArgb(0, 0, 0, 0);
        }

        var dark = 1;
        DwmSetWindowAttribute(hwnd, DwmwaUseImmersiveDarkMode, ref dark, sizeof(int));
        var corner = DwmwcpDoNotRound;
        DwmSetWindowAttribute(hwnd, DwmwaWindowCornerPreference, ref corner, sizeof(int));

        if (!acrylic)
            return;

        var backdrop = DwmSbtTransientWindow;
        var hr = DwmSetWindowAttribute(hwnd, DwmwaSystemBackdropType, ref backdrop, sizeof(int));
        if (hr != 0)
            window.Background = ((MainWindow)window).ThemeBackground;
    }

    public static bool TryGetPrimaryMonitor(out RECT rect)
    {
        rect = default;
        var monitor = MonitorFromPoint(new POINT(), MonitorDefaultToPrimary);
        if (monitor == IntPtr.Zero)
            return false;
        var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (!GetMonitorInfo(monitor, ref info))
            return false;
        rect = info.rcMonitor;
        return true;
    }

    private static IntPtr MouseActivate(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WmMouseActivate)
            return IntPtr.Zero;
        handled = true;
        return new IntPtr(MaNoActivate);
    }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong(IntPtr hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")]
    private static extern int SetWindowLong(IntPtr hwnd, int index, int value);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(POINT point, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }
}
