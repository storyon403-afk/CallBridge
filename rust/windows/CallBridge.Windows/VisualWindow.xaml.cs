// 浏览器保留现有最终画布与动作算法；采集授权限定本机源，隐藏/关闭作废整条输出管道。
using System.ComponentModel;
using System.IO;
using System.Text.Json;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;

namespace CallBridge.Windows;

public partial class VisualWindow : Window
{
    private readonly App _app;
    private readonly MainWindow _main;
    private readonly SemaphoreSlim _lifecycle = new(1, 1);
    private AvatarHost? _host;
    private CancellationTokenSource _load = new();
    private string? _background, _character;
    private VisualSnapshot _snapshot = new("avatar", "original", null, null);
    private bool _selecting;
    private bool _closed, _initialized;
    internal VisualWindow(App app, MainWindow main)
    {
        _app = app; _main = main; InitializeComponent();
        app.Workspace.Register("visual-runtime", this, canFold: false);
        StateChanged += async (_, _) => { if (WindowState == WindowState.Minimized) await StopAsync(); };
        IsVisibleChanged += async (_, _) => { if (!IsVisible && !_closed) await StopAsync(); };
        Closing += CloseRequested;
    }
    private async Task InitializeBrowserAsync()
    {
        if (_initialized) return;
        var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(Preferences.DataDirectory, "WebView2"));
        await Browser.EnsureCoreWebView2Async(environment);
        Browser.CoreWebView2.Settings.AreDevToolsEnabled = false;
        Browser.CoreWebView2.Settings.IsStatusBarEnabled = false;
        Browser.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
        Browser.CoreWebView2.PermissionRequested += (_, e) =>
        {
            e.SavesInProfile = false;
            e.State = CoreWebView2PermissionState.Deny;
            if (e.PermissionKind != CoreWebView2PermissionKind.Camera || !Allowed(e.Uri) || !IsVisible || WindowState == WindowState.Minimized) return;
            if (MessageBox.Show(this, "允许本次开启摄像头以驱动角色？画面仅在本机处理；视频输出需要单独开启。", "摄像头授权", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                e.State = CoreWebView2PermissionState.Allow;
        };
        Browser.CoreWebView2.NavigationStarting += (_, e) => { if (e.Uri != "about:blank" && !Allowed(e.Uri)) e.Cancel = true; };
        Browser.CoreWebView2.NewWindowRequested += (_, e) => e.Handled = true;
        Browser.CoreWebView2.DownloadStarting += (_, e) => e.Cancel = true;
        Browser.CoreWebView2.ProcessFailed += async (_, _) => { await StopAsync(); Status.Text = "画面进程中断，输出已停止"; };
        _initialized = true;
    }
    private bool Allowed(string url) => Uri.TryCreate(url, UriKind.Absolute, out var uri) && _host?.Origin is { } origin &&
        uri.Scheme == origin.Scheme && uri.Host == origin.Host && uri.Port == origin.Port;
    private async Task ReloadAsync()
    {
        _load.Cancel(); _load.Dispose(); _load = new(); var token = _load.Token;
        await _lifecycle.WaitAsync();
        try
        {
            token.ThrowIfCancellationRequested();
            await StopHostAsync();
            await InitializeBrowserAsync(); token.ThrowIfCancellationRequested();
            _host = new AvatarHost();
            var origin = await _host.StartAsync(_background, _character, token);
            token.ThrowIfCancellationRequested();
            var composition = new { person = _snapshot.Person, background = _snapshot.Background, backgroundOnly = _snapshot.BackgroundOnly, character = _snapshot.Person == "avatar" && _character != null };
            // 每次新导航先清除旧脚本，避免已导入资源或配置自动叠加。
            if (_compositionScript != null) Browser.CoreWebView2.RemoveScriptToExecuteOnDocumentCreated(_compositionScript);
            _compositionScript = await Browser.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(
                "window.callbridgeNative=true;window.callbridgeComposition=" + JsonSerializer.Serialize(composition) +
                ";document.addEventListener('DOMContentLoaded',()=>document.documentElement.classList.add('native-host'),{once:true});");
            // 活动状态由页面中真实的采集/发送控件展示，宿主不能保留过期的“未发送”标签。
            Browser.Source = origin; Status.Text = "";
        }
        catch (OperationCanceledException) { await StopHostAsync(); }
        catch (Exception e) { await StopHostAsync(); Status.Text = "画面不可用：" + e.Message; }
        finally { _lifecycle.Release(); }
    }
    private string? _compositionScript;
    private async Task StopHostAsync()
    {
        if (_initialized)
        {
            try { await Browser.ExecuteScriptAsync("window.avatarLab?.stop()").WaitAsync(TimeSpan.FromSeconds(2)); } catch (Exception) { /* 页面崩溃时仍关闭宿主管道。 */ }
            try { Browser.CoreWebView2.Navigate("about:blank"); } catch (Exception) { /* WebView 故障不能跳过管道/Job 清理。 */ }
        }
        if (_host != null) { await _host.DisposeAsync(); _host = null; }
    }
    internal async Task<bool> StopAsync()
    {
        _load.Cancel();
        await _lifecycle.WaitAsync();
        try { await StopHostAsync(); Status.Text = "已停止 · 点击重新加载准备画面"; return true; }
        catch (Exception e) { Status.Text = "停止失败：" + e.Message; return false; }
        finally { _lifecycle.Release(); }
    }
    internal async Task OpenAsync(VisualSnapshot snapshot)
    {
        _snapshot = snapshot; _background = snapshot.BackgroundPath; _character = snapshot.CharacterPath;
        _selecting = true;
        PersonChoice.ItemsSource = new[] { "真人", _character == null ? "澄 · 通话装" : Path.GetFileNameWithoutExtension(_character), "纯背景" };
        PersonChoice.SelectedIndex = FramingIndex(snapshot);
        BackgroundChoice.ItemsSource = BackgroundKinds.Select(VisualCatalogWindow.BackgroundName).ToArray();
        BackgroundChoice.SelectedIndex = Array.IndexOf(BackgroundKinds, snapshot.Background); _selecting = false;
        await ReloadAsync();
    }
    private static int FramingIndex(VisualSnapshot setup) => setup.BackgroundOnly ? 2 : setup.Person == "avatar" ? 1 : 0;
    private static readonly string[] BackgroundKinds = ["original", "plate", "sample", "parallax", "custom", "image"];
    private void Back(object sender, RoutedEventArgs e) => _app.Workspace.Back(this);
    private async void Reload(object sender, RoutedEventArgs e) => await ReloadAsync();
    private async void EffectsChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_selecting || BackgroundChoice.SelectedIndex < 0) return;
        var background = BackgroundKinds[BackgroundChoice.SelectedIndex];
        if (PersonChoice.SelectedIndex == 2 && background is ("original" or "plate"))
        {
            _selecting = true; PersonChoice.SelectedIndex = FramingIndex(_snapshot);
            BackgroundChoice.SelectedIndex = Array.IndexOf(BackgroundKinds, _snapshot.Background); _selecting = false;
            Status.Text = "纯背景模式需要图片或动画背景"; return;
        }
        if (background is "custom" or "image" && (_background == null || (background == "image") != new[] { ".png", ".jpg", ".jpeg" }.Contains(Path.GetExtension(_background).ToLowerInvariant())))
        {
            _selecting = true; PersonChoice.SelectedIndex = FramingIndex(_snapshot);
            BackgroundChoice.SelectedIndex = Array.IndexOf(BackgroundKinds, _snapshot.Background); _selecting = false;
            _app.OpenVisualCatalog(this, "dynamic", true); return;
        }
        _snapshot = _snapshot with { Person = PersonChoice.SelectedIndex == 1 ? "avatar" : "none", Background = background, BackgroundOnly = PersonChoice.SelectedIndex == 2 };
        // 配置切换只重新准备本地画面，不恢复摄像头授权或视频发送。
        await ReloadAsync();
    }
    private async void CloseRequested(object? sender, CancelEventArgs e)
    {
        if (_closed) return; e.Cancel = true; await CloseAsync();
    }
    internal async Task CloseAsync()
    {
        if (_closed) return;
        if (!await StopAsync()) return;
        _closed = true; _app.VisualPanel = null; Browser.Dispose(); Close();
    }
}
