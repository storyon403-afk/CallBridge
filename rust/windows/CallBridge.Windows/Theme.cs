// 把已确认的中性灰面板映射到 Windows；外观只更新画刷和 DWM，不接触媒体会话。
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace CallBridge.Windows;

internal static class Theme
{
    private static Application? _app;
    private static bool _dark, _material;
    internal static void Start(Application app)
    {
        _app = app;
        Refresh();
        EventManager.RegisterClassHandler(typeof(Window), FrameworkElement.LoadedEvent,
            new RoutedEventHandler((sender, e) => { if (ReferenceEquals(sender, e.OriginalSource)) ApplyWindow((Window)sender); }));
        SystemEvents.UserPreferenceChanged += PreferencesChanged;
        SystemParameters.StaticPropertyChanged += SystemChanged;
    }
    internal static void Stop()
    {
        SystemEvents.UserPreferenceChanged -= PreferencesChanged;
        SystemParameters.StaticPropertyChanged -= SystemChanged;
        _app = null;
    }
    private static void PreferencesChanged(object sender, UserPreferenceChangedEventArgs e) => QueueRefresh();
    private static void SystemChanged(object? sender, PropertyChangedEventArgs e) => QueueRefresh();
    private static void QueueRefresh()
    {
        if (_app is { } app && !app.Dispatcher.HasShutdownStarted)
            app.Dispatcher.BeginInvoke(Refresh);
    }
    private static int Preference(string name, int fallback)
    {
        try { return Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", name, fallback) is int value ? value : fallback; }
        catch (Exception error) when (error is UnauthorizedAccessException or System.IO.IOException or System.Security.SecurityException) { return fallback; }
    }
    private static void Refresh()
    {
        var app = _app;
        if (app == null) return;
        var contrast = SystemParameters.HighContrast;
        _dark = !contrast && Preference("AppsUseLightTheme", 1) == 0;
        _material = !contrast && (_app as App)?.Preferences.Translucent == true && Preference("EnableTransparency", 1) != 0 && OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621);
        void Set(string name, string light, string dark, Brush accessible)
        {
            if (contrast) { app.Resources[name] = accessible; return; }
            var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(_dark ? dark : light));
            brush.Freeze(); app.Resources[name] = brush;
        }
        Set("ShellBrush", "#F5F5F5", "#282828", SystemColors.WindowBrush);
        Set("CardBrush", "#FFFFFF", "#1F1F1F", SystemColors.ControlBrush);
        Set("RaisedBrush", "#E8E8E8", "#363636", SystemColors.ControlBrush);
        Set("HoverBrush", "#E0E0E0", "#414141", SystemColors.HighlightBrush);
        Set("InkBrush", "#282828", "#E2E2E2", SystemColors.WindowTextBrush);
        Set("MutedBrush", "#676767", "#A0A0A0", SystemColors.WindowTextBrush);
        Set("LineBrush", "#18000000", "#19FFFFFF", SystemColors.WindowTextBrush);
        Set("PrimaryBrush", "#303030", "#DEDEDE", SystemColors.HighlightBrush);
        Set("PrimaryInkBrush", "#FFFFFF", "#282828", SystemColors.HighlightTextBrush);
        Set("FocusBrush", "#396BB2", "#8AAFEC", SystemColors.HighlightBrush);
        foreach (Window window in app.Windows) ApplyWindow(window);
    }
    private static void ApplyWindow(Window window)
    {
        if (window is TabWindow) return;
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero) return;
        var dark = _dark ? 1 : 0;
        DwmSetWindowAttribute(handle, 20, ref dark, sizeof(int));
        var backdrop = _material ? 2 : 1;
        var enabled = OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621) &&
                      DwmSetWindowAttribute(handle, 38, ref backdrop, sizeof(int)) >= 0 && _material;
        var margins = enabled ? new Margins(-1) : new Margins(0);
        if (DwmExtendFrameIntoClientArea(handle, ref margins) < 0) enabled = false;
        // 材质不可用或用户关闭透明时保留完整实色面板，绝不能变成黑色/空白窗口。
        window.SetResourceReference(Window.BackgroundProperty, "ShellBrush");
        if (enabled) window.Background = Brushes.Transparent;
        if (HwndSource.FromHwnd(handle)?.CompositionTarget is { } target)
            target.BackgroundColor = enabled ? Colors.Transparent : ((SolidColorBrush)window.FindResource("ShellBrush")).Color;
    }
    internal static void UpdateMaterial() => Refresh();
    [StructLayout(LayoutKind.Sequential)]
    private struct Margins(int value)
    {
        public int Left = value, Right = value, Top = value, Bottom = value;
    }
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    [DllImport("dwmapi.dll")]
    private static extern int DwmExtendFrameIntoClientArea(IntPtr window, ref Margins margins);
}
