// 与 Mac 保持相同的输入/变声/可选转文字/输出导航；未接入的引擎不开启采集，也不生成假结果。
using System.Windows;
using System.Windows.Controls;

namespace CallBridge.Windows;

internal sealed class TranscriptionWindow : ModuleWindow
{
    internal TranscriptionWindow(App app) : base(app, "transcription", "声音转录") { ReturnHome = () => Navigate("home"); Navigate("home"); }
    private void Navigate(string page)
    {
        UIElement body; var actions = new List<Button>(); var status = "未采集";
        switch (page)
        {
            case "input": case "output":
                var input = page == "input"; var menu = UI.Select(input ? "输入设备" : "试听设备");
                try { AudioWindow.SelectDevice(menu, input ? AudioController.InputDevices() : AudioController.Devices(), input ? Host.Preferences.MicrophoneId : Host.Preferences.PreviewId); }
                catch (Exception e) { status = e.Message; }
                menu.SelectionChanged += async (_, _) =>
                {
                    try
                    {
                        if (input) Host.Preferences.MicrophoneId = (menu.SelectedItem as OutputDevice)?.Id;
                        else { Host.TextPanel?.RevokePermission(); await Host.Audio.StopAsync(); Host.Preferences.PreviewId = (menu.SelectedItem as OutputDevice)?.Id; }
                        Host.Preferences.Save();
                    }
                    catch (Exception e) { Message(e.Message); }
                };
                body = UI.Column(UI.Hero(input ? "麦克风" : "耳机试听", "未采集"), UI.Card(UI.Label("设备", true), menu));
                if (!input) ((StackPanel)body).Children.Add(UI.Link("通话目标", "音频设置", () => Host.OpenAudio(this, "output")));
                if (status == "未采集") status = "选择设备不会采集"; actions.Add(UI.Button("完成", () => Navigate("home"))); break;
            case "voice":
                body = UI.Column(UI.Hero("添加变声插件", "暂无可用变声引擎"), UI.Card(UI.Link("音频插件", "查看兼容性", () => Navigate("plugins")), UI.Link("已有音色", "转录后朗读", () => Host.OpenAudio(this))));
                status = "不使用原声替代"; actions.Add(UI.Button("查看插件", () => Navigate("plugins"))); break;
            case "transcribe":
                var language = UI.Select("语言"); language.ItemsSource = new[] { "自动识别", "中文", "English" }; language.SelectedItem = Host.Preferences.RecognitionLanguage;
                language.SelectionChanged += (_, _) => Host.Preferences.RecognitionLanguage = language.SelectedItem as string ?? "自动识别";
                body = UI.Column(UI.Card(new CheckBox { Content = "启用转文字", IsEnabled = false, ToolTip = "识别引擎待接入" }, UI.Label("语言", true), language, UI.Link("引擎", "待接入", () => Navigate("plugins"))), UI.Link("转录文字", "本次会话", () => Navigate("transcript")));
                status = "识别引擎待接入"; actions.Add(UI.Button("完成", () => Navigate("home"))); break;
            case "transcript":
                body = UI.Hero("暂无转录", "本次会话"); actions.Add(UI.Button("打开文字窗", () => Host.OpenText(this))); break;
            case "plugins":
                body = UI.Column(UI.Hero("音频插件", "按能力显示兼容性"), UI.Card(UI.Link("实时变声", "待适配", () => Navigate("voice")), UI.Link("语音识别", "待适配", () => Navigate("transcribe")), UI.Link("已有音色", "转录后朗读", () => Host.OpenAudio(this)), UI.Link("Pocket 降噪", "合成后处理", () => Host.OpenAudio(this, "plugins"))));
                status = "现有音色不支持实时变声"; actions.Add(UI.Button("管理音色", () => Host.OpenAudio(this))); break;
            default:
                page = "home";
                body = UI.Column(UI.Hero("未采集", "· · · · · · · · · · · · · ·"), UI.Card(UI.Link("输入", Host.Preferences.MicrophoneId == null ? "未选择" : "已选择", () => Navigate("input")), UI.Link("变声音色", "待接入", () => Navigate("voice")), UI.Link("同时转文字", "未启用", () => Navigate("transcribe")), UI.Link("输出", Host.Preferences.PreviewId == null ? "未选择" : "已选择", () => Navigate("output"))));
                status = "Windows 暂不支持实时变声与转录"; actions.Add(UI.Button("试听", () => { }, false, status)); break;
        }
        ShowPage(page, page switch { "input" => "输入", "output" => "输出", "voice" => "变声音色", "transcribe" => "同时转文字", "plugins" => "音频插件", "transcript" => "转录文字", _ => "" }, body, actions.ToArray()); Message(status);
    }
}
