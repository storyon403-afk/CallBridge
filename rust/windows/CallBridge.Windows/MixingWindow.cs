// 混音概要与文件/真实环境详情保持 Mac 的层级。未接入的常驻采集明确禁用，不能暗中透传原声。
using System.IO;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace CallBridge.Windows;

internal sealed class MixingWindow : ModuleWindow
{
    private string? _file;
    internal MixingWindow(App app) : base(app, "mixing", "混音设置")
    { ReturnHome = () => Navigate("home"); app.Audio.Status += Message; Closed += (_, _) => app.Audio.Status -= Message; Navigate("home"); }
    private void Navigate(string page)
    {
        UIElement body;
        if (page == "background")
        {
            var loop = new CheckBox { Content = "循环", IsChecked = Host.Audio.BackgroundLoop };
            loop.Click += (_, _) => Host.Audio.BackgroundLoop = loop.IsChecked == true;
            body = UI.Column(UI.Card(UI.Label(_file == null ? "未选择文件" : Path.GetFileName(_file)), UI.Row(UI.Button("导入文件", async () => await Import()), UI.Button("移除", () => { Host.Audio.Background = null; _file = null; Navigate(page); }))),
                UI.Card(UI.Row(UI.Button("暂停", () => { }, false, "Windows 常驻背景播放待适配"), loop)),
                UI.Row(UI.Button("官方插件", () => Host.OpenAudio(this, "catalog")), UI.Button("本地导入", () => Host.OpenAudio(this, "import"))));
        }
        else if (page == "environment")
        {
            var devices = UI.Select("真实环境麦克风");
            try { AudioWindow.SelectDevice(devices, AudioController.InputDevices(), Host.Preferences.MicrophoneId); } catch (Exception e) { Message(e.Message); }
            devices.SelectionChanged += (_, _) => { Host.Preferences.MicrophoneId = (devices.SelectedItem as OutputDevice)?.Id; Host.Preferences.Save(); };
            body = UI.Card(UI.Label("真实环境麦克风", true), devices, UI.Label("Windows 环境音采集待适配；选择设备不会开启采集。", true));
        }
        else
        {
            var gain = new Slider { Minimum = 0, Maximum = 1, Value = Host.Audio.BackgroundGain };
            var value = UI.Label($"背景 {gain.Value:P0}", true); gain.ValueChanged += (_, _) => { Host.Audio.BackgroundGain = (float)gain.Value; value.Text = $"背景 {gain.Value:P0}"; };
            body = UI.Column(UI.Card(UI.Link("文件背景", "", () => Navigate("background")), UI.Label(_file == null ? "未选择文件" : Path.GetFileName(_file), true), UI.GainRow(value, gain)),
                UI.Card(UI.Link("真实环境", "", () => Navigate("environment")), new CheckBox { Content = "开启真实环境", IsEnabled = false, ToolTip = "Windows 环境音采集待适配" }, UI.GainRow(UI.Label("环境 25%", true), new Slider { Minimum = 0, Maximum = 1, Value = .25, IsEnabled = false })));
        }
        Message("文件随直接发送混入 · 常驻混音待适配");
        ShowPage(page, page == "background" ? "文件背景" : page == "environment" ? "真实环境" : "", body, UI.Button("■", Host.StopMedia, help: "停止全部"), UI.Button("文字输入", () => Host.OpenText(this)));
    }
    private async Task Import()
    {
        if (Host.Audio.Busy) { Message("请先停止音频"); return; }
        var picker = new OpenFileDialog { Filter = "音频文件|*.wav;*.mp3;*.aiff;*.wma" };
        if (picker.ShowDialog(this) != true) return;
        try
        {
            var pcm = await Task.Run(() => AudioController.LoadBackground(picker.FileName));
            if (Host.Audio.Busy || !IsLoaded) return;
            Host.Audio.Background = pcm; _file = picker.FileName; Navigate("background"); Message("已载入 · 未播放");
        }
        catch (Exception e) { Message(e.Message); }
    }
}
