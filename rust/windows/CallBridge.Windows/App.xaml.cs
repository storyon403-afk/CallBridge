// Windows 入口只组织窗口与系统事件；关闭/睡眠必须作废媒体会话，恢复不自动发送。
using System.Windows;
using Microsoft.Win32;

namespace CallBridge.Windows;

public partial class App : Application
{
    internal AudioController Audio { get; } = new();
    internal Preferences Preferences { get; } = Preferences.Load();
    internal TextWindow? TextPanel;
    internal VisualWindow? VisualPanel;
    internal Workspace Workspace { get; private set; } = null!;
    internal MainWindow MainPanel = null!;
    internal VisualSelection Visuals { get; } = new();
    internal bool Exiting;
    private System.Windows.Forms.NotifyIcon? _tray;
    private System.Drawing.Icon? _trayIcon;
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) ||
            System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture != System.Runtime.InteropServices.Architecture.X64)
        {
            MessageBox.Show("此开发版需要 Windows 11 x64。", "CallBridge"); Shutdown(1); return;
        }
        Workspace = new(this); Theme.Start(this);
        SystemEvents.PowerModeChanged += OnPower;
        SystemEvents.SessionSwitch += OnSession;
        MainPanel = new MainWindow(this);
        // 从应用资源加载同一品牌图标；托盘重建时仍需要持有它。
        using (var stream = GetResourceStream(new Uri("pack://application:,,,/CallBridge.ico")).Stream)
        using (var source = new System.Drawing.Icon(stream, System.Windows.Forms.SystemInformation.SmallIconSize))
            _trayIcon = (System.Drawing.Icon)source.Clone();
        _tray = new System.Windows.Forms.NotifyIcon { Icon = _trayIcon, Text = "CallBridge", Visible = true };
        _tray.DoubleClick += (_, _) => Dispatcher.Invoke(() => Workspace.Show("main"));
        var trayMenu = new System.Windows.Forms.ContextMenuStrip();
        trayMenu.Items.Add("打开主面板", null, (_, _) => Dispatcher.Invoke(() => Workspace.Show("main")));
        trayMenu.Items.Add("文字输入", null, (_, _) => Dispatcher.Invoke(() => OpenText(null)));
        trayMenu.Items.Add("停止全部", null, (_, _) => Dispatcher.Invoke(StopMedia));
        trayMenu.Items.Add("退出", null, (_, _) => Dispatcher.Invoke(async () => await RequestQuitAsync()));
        _tray.ContextMenuStrip = trayMenu;
        if (e.Args.Contains("--text")) OpenText(null); else Workspace.Show("main");
    }
    internal void OpenText(Window? from)
    {
        TextPanel ??= new TextWindow(this, MainPanel); Workspace.Show("text", from);
    }
    internal void OpenAudio(Window? from, string? page = null)
    {
        var window = Workspace.Get("audio") as AudioWindow ?? new AudioWindow(this);
        if (page != null) window.Navigate(page); Workspace.Show("audio", from);
    }
    internal void OpenMixing(Window? from)
    {
        _ = Workspace.Get("mixing") ?? new MixingWindow(this); Workspace.Show("mixing", from);
    }
    internal void OpenVisualCatalog(Window? from, string? page = null, bool pairing = false)
    {
        OpenVisualPage(from, page ?? "home", pairing);
    }
    internal void OpenVisualPage(Window? from, string page, bool pairing = false, string detail = "person", string background = "plate", string parent = "virtual")
    {
        var id = page == "home" ? "visual" : "visual/" + (page == "detail" ? detail + (detail == "background" ? "/" + background : "") : page);
        var window = Workspace.Get(id) as VisualCatalogWindow ?? new VisualCatalogWindow(this, id, page, detail, background, parent);
        window.Render(page, pairing); Workspace.Show(id, from);
    }
    internal void OpenTranscription(Window? from)
    {
        _ = Workspace.Get("transcription") ?? new TranscriptionWindow(this); Workspace.Show("transcription", from);
    }
    internal void OpenServices(Window? from)
    {
        _ = Workspace.Get("services") ?? new ServicesWindow(this); Workspace.Show("services", from);
    }
    internal void Help() => MessageBox.Show("在组合台选择音色、人物和背景，在接线台分别选择本机试听和通话输出设备。点击打字说话编辑草稿，或点击打开画面预览。摄像头和视频输出需要分别开启。顶部标签双击展开；窗口菜单可设置置顶。", "CallBridge");
    internal async Task RequestQuitAsync()
    {
        try { await QuitAsync(); } catch (Exception e) { MessageBox.Show("退出清理失败：" + e.Message, "CallBridge"); }
    }
    private void OnPower(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend) Dispatcher.BeginInvoke(StopMedia);
    }
    private void OnSession(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionLock) Dispatcher.BeginInvoke(StopMedia);
    }
    internal async void StopMedia()
    {
        try
        {
            TextPanel?.RevokePermission();
            await Audio.StopAsync();
        }
        catch (Exception e) { MessageBox.Show("音频停止失败：" + e.Message, "CallBridge"); }
        finally { if (VisualPanel != null) await VisualPanel.StopAsync(); }
    }
    internal async Task QuitAsync()
    {
        TextPanel?.RevokePermission();
        await Audio.StopAsync();
        if (VisualPanel != null) await VisualPanel.CloseAsync();
        if (VisualPanel != null) throw new InvalidOperationException("视频清理未完成，请查看画面窗口错误");
        Preferences.Save();
        Exiting = true; Workspace.Dispose();
        Shutdown();
    }
    protected override void OnExit(ExitEventArgs e)
    {
        Theme.Stop();
        _tray?.Dispose();
        _trayIcon?.Dispose();
        SystemEvents.PowerModeChanged -= OnPower;
        SystemEvents.SessionSwitch -= OnSession;
        base.OnExit(e);
    }
}
