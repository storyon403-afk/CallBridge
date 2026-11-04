// 对齐 Mac 音频概要与 voice/output/plugins 详情；重复进入复用选项与页面，不创建第二套状态。
using System.Windows;
using System.Windows.Controls;

namespace CallBridge.Windows;

public partial class AudioWindow : ModuleWindow
{
    private readonly ComboBox _voices = UI.Select("声音"), _outputs = UI.Select("通话输出"), _previews = UI.Select("本机试听");
    private bool _loading;
    internal AudioWindow(App app) : base(app, "audio", "音频模拟")
    {
        InitializeComponent(); ReturnHome = () => Navigate(CurrentPage is "catalog" or "import" ? "plugins" : "home");
        _voices.SelectionChanged += SelectionChanged; _outputs.SelectionChanged += SelectionChanged; _previews.SelectionChanged += SelectionChanged;
        app.Audio.Status += UpdateStatus; Closed += (_, _) => app.Audio.Status -= UpdateStatus;
        LoadDevices(); Navigate("home");
    }
    private void UpdateStatus(string text) => Message(text);
    private Button StopButton() => UI.Button("■", Host.StopMedia, help: "停止全部");
    internal void Navigate(string page)
    {
        // 移除旧视图后再把共享控件放入详情；同一 ComboBox 不产生镜像状态。
        Page.Content = null;
        Detach(_voices); Detach(_outputs); Detach(_previews);
        UIElement body;
        switch (page)
        {
            case "voice":
                body = UI.Column(UI.Card(UI.Label("声音", true), _voices,
                    UI.Link("语音输出", "系统 TTS", () => { }),
                    UI.Link("降噪效果", "Windows 待适配", () => { }, false)),
                    UI.Row(UI.Button("试听", async () => await Preview()), UI.Button("刷新", LoadDevices))); break;
            case "output":
                body = UI.Column(UI.Card(UI.Label("本机试听", true), _previews), UI.Card(UI.Label("通话输出", true), _outputs),
                    UI.Link("路由帮助", "虚拟音频播放端 → 通话录音端", Host.Help), UI.Button("刷新设备", LoadDevices)); break;
            case "plugins":
                body = UI.Column(UI.Hero("中文 Pocket", "Windows 引擎待适配"), UI.Hero("English Pocket", "Windows 引擎待适配"),
                    UI.Row(UI.Button("官方插件", () => Navigate("catalog")), UI.Button("本地导入", () => Navigate("import"))),
                    UI.Link("云端服务", "", () => Host.OpenServices(this))); break;
            case "catalog":
                body = UI.Column(UI.Hero("官方插件", "暂无已验证的 Windows 插件"), UI.Label("macOS 插件不能直接启用。", true)); break;
            case "import":
                body = UI.Column(UI.Hero("本地音频插件", "Windows 插件安装器待适配"), UI.Button("选择插件包", () => { }, false, "当前无法校验并启用 Windows 音频插件")); break;
            case "personal":
                body = UI.Column(UI.Hero("个人音色", "Windows 编码器待适配"), UI.Row(UI.Button("中文", () => { }, false), UI.Button("English", () => { }, false)), UI.Button("导入声音样本", () => { }, false)); break;
            default:
                page = "home";
                body = UI.Column(UI.Card(UI.Row(new TextBlock { Text = Host.Preferences.Voice ?? "系统默认音色", FontWeight = FontWeights.SemiBold, MaxWidth = 210, TextTrimming = TextTrimming.CharacterEllipsis }, UI.Button("试听", async () => await Preview())),
                    UI.Label("Windows 系统语音", true), UI.Link("选择音色与效果", "", () => Navigate("voice"))),
                    UI.Card(UI.Link("输出设备", (_outputs.SelectedItem as OutputDevice)?.Name ?? "未选择", () => Navigate("output")), UI.Link("音频插件", "", () => Navigate("plugins"))),
                    UI.Link("个人音色", "", () => Navigate("personal"))); break;
        }
        ShowPage(page, page switch { "voice" => "声音", "output" => "输出设备", "plugins" => "音频插件", "personal" => "个人音色", "catalog" => "官方插件", "import" => "本地导入", _ => "" }, body,
            StopButton(), UI.Button("文字输入", () => Host.OpenText(this)));
        Message(Host.Audio.LastStatus);
    }
    private static void Detach(FrameworkElement control) { if (control.Parent is Panel panel) panel.Children.Remove(control); }
    private async Task Preview()
    {
        try
        {
            if (Host.Preferences.PreviewId == Host.Preferences.OutputId) throw new InvalidOperationException("请选择独立的本机试听设备");
            await Host.Audio.SpeakAsync("你好，这是 CallBridge 的声音试听。", Host.Preferences.Voice, Host.Preferences.PreviewId, true, false);
        }
        catch (Exception e) { Message(e.Message); }
    }
    private void LoadDevices()
    {
        _loading = true;
        try
        {
            var devices = AudioController.Devices();
            SelectDevice(_outputs, devices, Host.Preferences.OutputId); SelectDevice(_previews, devices, Host.Preferences.PreviewId);
            _voices.ItemsSource = AudioController.Voices(); _voices.SelectedItem = Host.Preferences.Voice;
        }
        catch (Exception e) { Message(e.Message); }
        finally { _loading = false; }
    }
    internal static void SelectDevice(ComboBox combo, OutputDevice[] devices, string? id)
    {
        var list = devices.ToList();
        if (id != null && list.All(d => d.Id != id)) list.Insert(0, new(id, "设备不可用（保留选择）"));
        combo.ItemsSource = list; combo.SelectedItem = list.FirstOrDefault(d => d.Id == id);
    }
    private async void SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        try
        {
            Host.TextPanel?.RevokePermission(); await Host.Audio.StopAsync();
            if (ReferenceEquals(sender, _outputs)) Host.Preferences.OutputId = (_outputs.SelectedItem as OutputDevice)?.Id;
            if (ReferenceEquals(sender, _previews)) Host.Preferences.PreviewId = (_previews.SelectedItem as OutputDevice)?.Id;
            if (ReferenceEquals(sender, _voices)) Host.Preferences.Voice = _voices.SelectedItem as string;
            Host.Preferences.Save(); Message("已选择 · 未发送");
        }
        catch (Exception error) { Message(error.Message); }
    }
}
