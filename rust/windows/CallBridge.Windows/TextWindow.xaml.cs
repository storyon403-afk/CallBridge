// 同一个编辑器保留草稿、中文输入法与撤销。收起不停止音频；关闭会撤权并等待清理。
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;

namespace CallBridge.Windows;

public partial class TextWindow : Window
{
    private readonly App _app;
    private bool _closing;
    private double _compactWidth = 560;
    private Size _expanded = new(560, 420);
    private bool _outputAvailable, _previewAvailable, _sameDevice;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private double _deadline;
    internal bool Expanded => Details.Visibility == Visibility.Visible;
    internal TextWindow(App app, MainWindow main)
    {
        _app = app; InitializeComponent(); Gain.Value = app.Preferences.Gain;
        app.Workspace.Register("text", this);
        _app.Audio.Status += UpdateStatus; Closing += CloseRequested;
        Activated += (_, _) => RefreshRoute();
        _timer.Tick += Tick; _timer.Start();
        Closed += (_, _) => { _timer.Stop(); _app.Audio.Status -= UpdateStatus; };
        PreviewKeyDown += (_, e) =>
        {
            // ImeProcessed 不匹配 Enter，避免抢占中文组字确认。
            if (Keyboard.Modifiers != ModifierKeys.Control) return;
            if (e.Key == Key.Enter) { e.Handled = true; Send(this, new RoutedEventArgs()); }
            else if (e.Key == Key.OemPeriod) { e.Handled = true; Stop(this, new RoutedEventArgs()); }
        };
    }
    private void UpdateStatus(string value) { Status.Text = value; Status.ToolTip = value; }
    internal void RefreshRoute()
    {
        // 只在进入窗口或设备选择变化时枚举，不能放进每 100 ms 的倒计时刷新。
        try
        {
            var devices = AudioController.Devices();
            var output = devices.FirstOrDefault(d => d.Id == _app.Preferences.OutputId);
            var preview = devices.FirstOrDefault(d => d.Id == _app.Preferences.PreviewId);
            _outputAvailable = output != null; _previewAvailable = preview != null;
            _sameDevice = output != null && output.Id == preview?.Id;
            TargetLabel.Text = "发送到：" + (output?.Name ?? (_app.Preferences.OutputId == null ? "未选择设备" : "设备不可用"));
            TargetLabel.ToolTip = TargetLabel.Text + "\n本机试听：" + (preview?.Name ?? "未选择可用设备");
            RouteWarning.Text = !_outputAvailable ? "请先选择可用的通话输出设备。" : _sameDevice ? "试听与发送使用同一设备，请在设备设置中分开选择。" : !_previewAvailable ? "尚未选择本机试听设备。" : "";
            RouteWarning.Visibility = RouteWarning.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        catch (Exception error)
        {
            _outputAvailable = _previewAvailable = false; _sameDevice = false;
            TargetLabel.Text = "发送到：设备读取失败"; TargetLabel.ToolTip = error.Message;
            RouteWarning.Text = "无法读取音频设备，请打开设备设置重试。"; RouteWarning.Visibility = Visibility.Visible;
        }
        if (!_outputAvailable && Permission.IsChecked == true) RevokePermission();
        Permission.IsEnabled = _outputAvailable;
        RefreshControls();
    }
    internal void RevokePermission() { _deadline = 0; Permission.IsChecked = false; }
    private async void PermissionRevoked(object sender, RoutedEventArgs e)
    {
        _deadline = 0;
        if (IsInitialized) await Run(() => _app.Audio.StopAsync());
    }
    private void PermissionChanged(object sender, RoutedEventArgs e) => RefreshControls();
    private void DraftChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        if (!IsInitialized) return;
        _deadline = 0; _app.Audio.DraftChanged(); RefreshControls();
    }
    private async Task Run(Func<Task> action)
    {
        try { await action(); } catch (Exception e) { UpdateStatus(e.Message); }
        finally { RefreshControls(); }
    }
    private async void Send(object sender, RoutedEventArgs e)
    {
        _deadline = 0; _app.Audio.CancelCountdown();
        if (Permission.IsChecked != true)
        {
            SetExpanded(true); UpdateStatus("请确认输出设备并允许发送"); return;
        }
        await Run(() => _app.Audio.SpeakAsync(Editor.Text, _app.Preferences.Voice, _app.Preferences.OutputId, false, true));
    }
    private async void Preview(object sender, RoutedEventArgs e)
    {
        _deadline = 0; _app.Audio.CancelCountdown();
        if (_app.Preferences.PreviewId == _app.Preferences.OutputId)
        { UpdateStatus("试听设备须与通话输出设备不同"); return; }
        await Run(() => _app.Audio.SpeakAsync(Editor.Text, _app.Preferences.Voice, _app.Preferences.PreviewId, true, false));
    }
    private async void Prepare(object sender, RoutedEventArgs e) { _deadline = 0; await Run(() => _app.Audio.PrepareAsync(Editor.Text, _app.Preferences.Voice)); }
    private void Countdown(object sender, RoutedEventArgs e)
    {
        if (_deadline != 0) { _deadline = 0; _app.Audio.CancelCountdown(); UpdateStatus("已备好 · 等待播放"); return; }
        if (Permission.IsChecked != true || !_app.Audio.Prepared || string.IsNullOrWhiteSpace(_app.Preferences.OutputId)) return;
        if (_app.Audio.BeginCountdown()) { _deadline = Now + 5; UpdateStatus("5 秒后播放 · 请切换到通话窗口"); }
    }
    private static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
    private async void Tick(object? sender, EventArgs e)
    {
        RefreshControls();
        if (_deadline == 0) return;
        if (!_app.Audio.CountingDown) { _deadline = 0; return; }
        var decision = PreparedCountdown.Decide(Now, _deadline, IsForeground(), Permission.IsChecked == true && _app.Audio.CountingDown);
        if (decision == CountdownDecision.Pending) { UpdateStatus($"{Math.Max(1, Math.Ceiling(_deadline - Now))} 秒后播放 · 请切换到通话窗口"); return; }
        _deadline = 0; _app.Audio.CancelCountdown();
        if (decision == CountdownDecision.Wait) { UpdateStatus("已备好 · 请切换到通话窗口后重新倒计时"); return; }
        await Run(() => _app.Audio.SpeakAsync(Editor.Text, _app.Preferences.Voice, _app.Preferences.OutputId, false, true));
    }
    // 模态对话框也属于本进程，不能只看 WPF 的 IsActive。
    private static bool IsForeground()
    {
        var foreground = GetForegroundWindow();
        if (foreground == IntPtr.Zero) return true;
        GetWindowThreadProcessId(foreground, out var process); return process == Environment.ProcessId;
    }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    private void RefreshControls()
    {
        if (!IsInitialized || CountdownButton == null) return;
        var idle = !_app.Audio.Busy; var text = !string.IsNullOrWhiteSpace(Editor.Text);
        SendButton.IsEnabled = idle && text && _outputAvailable; PreviewButton.IsEnabled = idle && text && _previewAvailable && !_sameDevice;
        SendButton.ToolTip = _outputAvailable ? "发送 · Ctrl+Enter" : "请先选择可用的输出设备";
        PreviewButton.ToolTip = _sameDevice ? "试听设备须与通话输出设备不同" : !_previewAvailable ? "请先选择本机试听设备" : "只在所选本机设备试听";
        PrepareButton.IsEnabled = idle && text; CountdownButton.IsEnabled = idle && (_app.Audio.Prepared || _app.Audio.CountingDown) && Permission.IsChecked == true && _outputAvailable;
        CountdownButton.Content = _app.Audio.CountingDown ? "取消倒计时" : "5 秒后播放";
        Pin.IsChecked = _app.Workspace.PinPanels;
    }
    private async void Stop(object sender, RoutedEventArgs e) { _deadline = 0; await Run(() => _app.Audio.StopAsync()); }
    private void Settings(object sender, RoutedEventArgs e) => _app.OpenAudio(this);
    private void OutputSettings(object sender, RoutedEventArgs e) => _app.OpenAudio(this, "output");
    private void PinChanged(object sender, RoutedEventArgs e) => _app.Workspace.Pin(_app.Workspace.PinWidgets, Pin.IsChecked == true);
    private void Expand(object sender, RoutedEventArgs e) => SetExpanded(!Expanded);
    private void SetExpanded(bool show)
    {
        if (show == Expanded) return;
        if (Expanded) _expanded = new(ActualWidth, ActualHeight); else _compactWidth = ActualWidth;
        // 紧凑态按 TextBox 的两行排版高度测量，不用固定像素截断中文行框。
        SizeToContent = SizeToContent.Manual;
        Details.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        Editor.MaxLines = show ? int.MaxValue : 2;
        // WPF 把 MaxLines 恢复为默认值时仍可能保留内部视口的两行上限。
        // 展开时用本地高度约束清除缓存；收起时恢复按行测量，编辑器实例与撤销记录不变。
        if (show) Editor.MinHeight = 0; else Editor.ClearValue(MinHeightProperty);
        Editor.VerticalAlignment = show ? VerticalAlignment.Stretch : VerticalAlignment.Top;
        Width = show ? _expanded.Width : _compactWidth;
        MinHeight = show ? 360 : 148;
        if (show) Height = _expanded.Height; else SizeToContent = SizeToContent.Height;
        ExpandButton.Content = show ? "⌃" : "⌄"; ExpandButton.ToolTip = show ? "收起" : "展开";
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() => Editor.ScrollToLine(Math.Max(0, Editor.GetLineIndexFromCharacterIndex(Editor.CaretIndex) - 1))));
    }
    private void GainChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_app == null) return;
        _app.Preferences.Gain = e.NewValue; _app.Audio.SetGain((float)e.NewValue);
        if (GainLabel != null) GainLabel.Text = $"{e.NewValue:P0}";
    }
    private async void CloseRequested(object? sender, CancelEventArgs e)
    {
        if (_app.Exiting) return;
        e.Cancel = true; if (_closing) return; _closing = true;
        try { RevokePermission(); await _app.Audio.StopAsync(); _app.Workspace.Dismiss(this); }
        catch (Exception error) { UpdateStatus("停止失败：" + error.Message); }
        finally { _closing = false; }
    }
}
