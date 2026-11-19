// 单实例页面与独立顶部标签：页面导航只折叠窗口，不重建控件、不开始或停止媒体。
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;

namespace CallBridge.Windows;

public static class PanelCommands
{
    public static RoutedCommand Fold { get; } = new();
    public static RoutedCommand Close { get; } = new();
    public static RoutedCommand Menu { get; } = new();
}

internal sealed class Workspace
{
    private readonly App _app;
    internal readonly Navigation State = new();
    private readonly Dictionary<string, Window> _windows = new();
    private readonly Dictionary<string, TabWindow> _tabs = new();
    private readonly Dictionary<string, Size> _sizes = new();
    private TabWindow? _overflow;
    private bool _overflowOpen;
    private int _offset;
    internal bool PinWidgets = true, PinPanels;
    private readonly DispatcherTimer _activity = new() { Interval = TimeSpan.FromMilliseconds(250) };
    internal Workspace(App app)
    {
        _app = app;
        _activity.Tick += (_, _) => { foreach (var (id, tab) in _tabs) tab.Activity((id is "main" or "text" or "audio" or "mixing") && (_app.Audio.Busy || _app.Audio.Prepared || _app.Audio.CountingDown), _app.Audio.LastStatus); };
        _activity.Start();
    }
    internal void Register(string id, Window window, bool canFold = true)
    {
        State.Register(id, canFold); _windows[id] = window;
        window.CommandBindings.Add(new(PanelCommands.Fold, (_, _) => Fold(window), (_, e) => e.CanExecute = canFold));
        window.CommandBindings.Add(new(PanelCommands.Close, (_, _) => window.Close()));
        window.CommandBindings.Add(new(PanelCommands.Menu, (_, _) => { var menu = Menu(window); menu.PlacementTarget = window; menu.IsOpen = true; }));
        window.Closed += (_, _) => { State.Unregister(id); _windows.Remove(id); RemoveTab(id); ArrangeTabs(); StopIfEmpty(); };
        window.SourceInitialized += (_, _) =>
        {
            // 缩放拖动结束才判断收起，输入框编辑和对话框不会触发此路径。
            HwndSource.FromHwnd(new WindowInteropHelper(window).Handle)?.AddHook((IntPtr hwnd, int message, IntPtr wparam, IntPtr lparam, ref bool handled) =>
            {
                if (message == 0x0232 && canFold && (window.Width < 252 || window.Height < (window is TextWindow text && !text.Expanded ? 112 : 168)))
                    window.Dispatcher.BeginInvoke(() => Fold(window));
                return IntPtr.Zero;
            });
        };
    }
    internal Window? Get(string id) => _windows.GetValueOrDefault(id);
    internal string? Id(Window? w) => _windows.FirstOrDefault(pair => pair.Value == w).Key;
    internal void Show(string id, Window? from = null)
    {
        var target = _windows[id]; var first = !State.Entries[id].Open;
        State.Show(id, Id(from));
        if (first)
        {
            var area = SystemParameters.WorkArea;
            target.Left = Math.Clamp(from?.Left ?? area.Left + (area.Width - target.Width) / 2, area.Left, Math.Max(area.Left, area.Right - target.Width));
            target.Top = Math.Clamp(from?.Top ?? area.Top + (area.Height - target.Height) / 2 - 50, area.Top + 56, Math.Max(area.Top + 56, area.Bottom - target.Height));
        }
        Sync(); target.Activate();
    }
    internal void Back(Window window)
    {
        if (Id(window) is not { } id) return;
        var parent = State.Back(id); Sync(); if (parent != null && _windows.TryGetValue(parent, out var w)) w.Activate();
    }
    internal void Fold(Window window)
    {
        if (Id(window) is not { } id || !State.Entries[id].CanFold) return;
        if (window.Width >= 252 && window.Height >= 112) _sizes[id] = new(window.Width, window.Height);
        State.Fold(id); Sync();
    }
    internal void Dismiss(Window window)
    {
        if (Id(window) is not { } id) return;
        State.Dismiss(id); window.Hide(); RemoveTab(id); ArrangeTabs(); StopIfEmpty();
    }
    private void StopIfEmpty() { if (!_app.Exiting && State.Entries.Values.All(e => !e.Open)) _app.StopMedia(); }
    private void Sync()
    {
        foreach (var (id, window) in _windows)
        {
            var entry = State.Entries[id]; window.Topmost = PinPanels;
            if (entry.Open && entry.Visible)
            {
                RemoveTab(id);
                if (!window.IsVisible)
                {
                    var size = id == "text" ? _sizes.GetValueOrDefault(id, new Size(window.Width >= 252 ? window.Width : 560, window.Height >= 112 ? window.Height : 112)) : new Size(400, 360);
                    // 组合台按实际桌面尺寸启动；恢复时保留用户调整后的宽高。
                    if (id != "main") { window.Width = size.Width; window.Height = size.Height; }
                    window.Show();
                }
                if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
            }
            else if (entry.Open)
            {
                if (window.IsVisible) { if (id == "text") _sizes[id] = new(window.Width, window.Height); window.Hide(); }
                if (!_tabs.ContainsKey(id)) _tabs[id] = new TabWindow(window.Title, () => Show(id), () => { var menu = Menu(window); menu.IsOpen = true; }, ArrangeTabs);
            }
        }
        ArrangeTabs();
    }
    private void RemoveTab(string id) { if (_tabs.Remove(id, out var tab)) tab.Close(); }
    private void ArrangeTabs()
    {
        var area = SystemParameters.WorkArea;
        var automatic = _tabs.Values.Where(t => !t.Detached).ToArray();
        foreach (var tab in _tabs.Values) { tab.Topmost = PinWidgets; if (tab.Detached && !tab.IsVisible) tab.Show(); }
        if (automatic.Length > 5)
        {
            if (_overflow == null) { _overflow = new TabWindow("…", () => { _overflowOpen = !_overflowOpen; ArrangeTabs(); }, () => { }, ArrangeTabs, singleClick: true); _overflow.MouseWheel += OverflowWheel; }
            _overflow.Topmost = PinWidgets; _overflow.Left = _overflowOpen ? area.Left + 16 : area.Left + (area.Width - _overflow.Width) / 2; _overflow.Top = area.Top + 16; _overflow.Show();
            var count = Math.Max(1, (int)((area.Height - 88) / 40)); _offset = Math.Clamp(_offset, 0, Math.Max(0, automatic.Length - count));
            for (var i = 0; i < automatic.Length; i++)
            {
                if (_overflowOpen && i >= _offset && i < _offset + count) { automatic[i].Left = area.Left + 16; automatic[i].Top = area.Top + 56 + (i - _offset) * 40; automatic[i].Show(); }
                else automatic[i].Hide();
            }
        }
        else
        {
            if (_overflow != null) { _overflow.Close(); _overflow = null; } _overflowOpen = false; _offset = 0;
            var left = area.Left + Math.Max(16, (area.Width - automatic.Sum(t => t.Width) - 8 * Math.Max(0, automatic.Length - 1)) / 2);
            foreach (var tab in automatic) { tab.Left = left; tab.Top = area.Top + 16; tab.Show(); left += tab.Width + 8; }
        }
    }
    private void OverflowWheel(object sender, MouseWheelEventArgs e) { _offset += e.Delta < 0 ? 1 : -1; ArrangeTabs(); e.Handled = true; }
    internal void Pin(bool widgets, bool panels) { PinWidgets = widgets; PinPanels = panels; foreach (var w in _windows.Values) w.Topmost = panels; ArrangeTabs(); }
    internal ContextMenu Menu(Window? window)
    {
        var menu = new ContextMenu();
        void Item(string name, Action action) { var item = new MenuItem { Header = name }; item.Click += (_, _) => action(); menu.Items.Add(item); }
        Item("打开主面板", () => Show("main")); Item("文字输入", () => _app.OpenText(window));
        if (window != null && Id(window) is { } id)
        {
            Item("展开", () => Show(id)); Item("收起", () => Fold(window));
            Item("返回顶部", () => { if (_tabs.TryGetValue(id, out var tab)) tab.Detached = false; ArrangeTabs(); });
            Item("关闭", window.Close);
        }
        Item("停止全部", _app.StopMedia);
        var widgets = new MenuItem { Header = "小组件置顶", IsCheckable = true, IsChecked = PinWidgets }; widgets.Click += (_, _) => Pin(widgets.IsChecked, PinPanels); menu.Items.Add(widgets);
        var panels = new MenuItem { Header = "面板置顶", IsCheckable = true, IsChecked = PinPanels }; panels.Click += (_, _) => Pin(PinWidgets, panels.IsChecked); menu.Items.Add(panels);
        Item("云端服务", () => _app.OpenServices(window)); Item("使用帮助", _app.Help); Item("退出", async () => await _app.RequestQuitAsync()); return menu;
    }
    internal void Dispose() { _activity.Stop(); foreach (var tab in _tabs.Values) tab.Close(); _overflow?.Close(); }
}

internal sealed class TabWindow : Window
{
    internal bool Detached;
    private readonly TextBlock _label;
    private readonly string _title;
    internal TabWindow(string title, Action open, Action menu, Action moved, bool singleClick = false)
    {
        _title = title; Title = title; Height = 32; Width = Math.Clamp(title.Length * 13 + 40, 64, 192);
        Style = null; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; AllowsTransparency = true;
        Background = System.Windows.Media.Brushes.Transparent; ShowInTaskbar = false; ShowActivated = false;
        _label = UI.Label(title); _label.TextTrimming = TextTrimming.CharacterEllipsis; _label.TextWrapping = TextWrapping.NoWrap;
        var border = new Border { CornerRadius = new CornerRadius(16), Padding = new Thickness(16, 6, 16, 6), Child = _label }; border.SetResourceReference(Border.BackgroundProperty, "ShellBrush"); _label.SetResourceReference(TextBlock.ForegroundProperty, "InkBrush"); Content = border;
        Point? down = null;
        MouseLeftButtonDown += (_, e) => { if (e.ClickCount == 2 || singleClick) { open(); e.Handled = true; } else down = e.GetPosition(this); };
        MouseMove += (_, e) => { if (down is { } p && e.LeftButton == MouseButtonState.Pressed && (e.GetPosition(this) - p).Length > 4) { down = null; Detached = true; DragMove(); moved(); } };
        MouseLeftButtonUp += (_, _) => down = null;
        MouseRightButtonUp += (_, _) => menu();
        KeyDown += (_, e) => { if (e.Key == Key.Escape && singleClick) { open(); e.Handled = true; } else if (e.Key is Key.Enter or Key.Space) { open(); e.Handled = true; } };
    }
    internal void Activity(bool active, string text) { _label.Text = (active ? "• " : "") + _title; ToolTip = active ? text : _title; }
}
