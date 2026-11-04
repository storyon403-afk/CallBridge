// 服务目录复用 Mac 的分组和离线指南。Windows 尚未接入的远端操作不可提交或保存密钥。
using System.IO;
using System.Windows;
using System.Windows.Controls;

namespace CallBridge.Windows;

internal sealed class ServicesWindow : ModuleWindow
{
    private string _provider = "decart", _filter = "实时视频";
    private readonly Dictionary<string, string> _names = new() { ["decart"] = "Decart", ["liveavatar"] = "LiveAvatar", ["tavus"] = "Tavus", ["xmov"] = "魔珐星云", ["zego"] = "ZEGO", ["fashn"] = "FASHN", ["heygen"] = "HeyGen", ["synthesia"] = "Synthesia" };
    internal ServicesWindow(App app) : base(app, "services", "云端服务")
    { ReturnHome = () => Navigate(CurrentPage is "config" or "guide" or "job" ? "provider" : "home"); Navigate("home"); }
    private void Navigate(string page)
    {
        UIElement body;
        if (page == "home")
        {
            var filter = UI.Select("服务分类"); filter.ItemsSource = new[] { "实时视频", "图片与视频" }; filter.SelectedItem = _filter;
            filter.SelectionChanged += (_, _) => { _filter = (string)filter.SelectedItem; Navigate("home"); };
            var list = UI.Column(filter);
            foreach (var id in _filter == "实时视频" ? new[] { "decart", "liveavatar", "tavus", "xmov", "zego" } : new[] { "fashn", "heygen", "synthesia" })
                list.Children.Add(UI.Link(_names[id], "待接入", () => { _provider = id; Navigate("provider"); }));
            list.Children.Add(UI.Link("API 接入说明", "", () => Navigate("api"))); body = list;
        }
        else if (page is "guide" or "api")
        {
            var file = Path.Combine(AppContext.BaseDirectory, "cloud-guides", (page == "api" ? "api" : _provider) + ".md");
            body = UI.Label(File.Exists(file) ? File.ReadAllText(file) : "离线指南缺失，请检查便携包是否完整解压。", true);
        }
        else if (page == "config")
            body = UI.Column(UI.Hero(_names[_provider], "Windows 凭据与云端适配待接入"), UI.Label("API Key", true), new PasswordBox { IsEnabled = false }, UI.Row(UI.Button("保存配置", () => { }, false), UI.Button("检查连接", () => { }, false)), UI.Link("配置指南", "", () => Navigate("guide")));
        else if (page == "job")
            body = UI.Column(UI.Hero("暂无任务", "Windows 云端图片任务待接入"), UI.Button("提交任务", () => { }, false));
        else
            body = UI.Column(UI.Hero(_names[_provider], "Windows 适配待接入"), UI.Card(UI.Link("连接配置", "未配置", () => Navigate("config")), UI.Link("配置指南", "", () => Navigate("guide")), UI.Link("任务记录", "暂无", () => Navigate("job"))), UI.Button("开始", () => { }, false));
        ShowPage(page, page == "home" ? "" : page == "api" ? "API 接入说明" : _names[_provider], body);
        Message("未连接 · 未创建远端会话");
    }
}
