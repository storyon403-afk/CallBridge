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
    private Size _compact = new(560, 112), _expanded = new(560, 360);
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private double _deadline;
    internal bool Expanded => Details.Visibility == Visibility.Visible;
    internal TextWindow(App app, MainWindow main)
    {
        _app = app; InitializeComponent(); Gain.Value = app.Preferences.Gain;
        app.Workspace.Register("text", this);
        _app.Audio.Status += UpdateStatus; Closing += CloseRequested;
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
        SendButton.IsEnabled = idle && text; PreviewButton.IsEnabled = idle && text;
        PrepareButton.IsEnabled = idle && text; CountdownButton.IsEnabled = idle && (_app.Audio.Prepared || _app.Audio.CountingDown) && Permission.IsChecked == true && _app.Preferences.OutputId != null;
        CountdownButton.Content = _app.Audio.CountingDown ? "取消倒计时" : "5 秒后播放";
        Pin.IsChecked = _app.Workspace.PinPanels;
    }
    private async void Stop(object sender, RoutedEventArgs e) { _deadline = 0; await Run(() => _app.Audio.StopAsync()); }
    private void Settings(object sender, RoutedEventArgs e) => _app.OpenAudio(this);
    private void PinChanged(object sender, RoutedEventArgs e) => _app.Workspace.Pin(_app.Workspace.PinWidgets, Pin.IsChecked == true);
    private void Expand(object sender, RoutedEventArgs e) => SetExpanded(!Expanded);
    private void SetExpanded(bool show)
    {
        if (show == Expanded) return;
        if (Expanded) _expanded = new(Width, Height); else _compact = new(Width, Height);
        Details.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        var size = show ? _expanded : _compact; Width = size.Width; Height = size.Height;
        ExpandButton.Content = show ? "⌃" : "⌄"; ExpandButton.ToolTip = show ? "收起" : "展开";
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
