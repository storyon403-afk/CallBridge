// 选择页不启动 Node/WebView；详情只有显式“打开”才创建运行快照，浏览其他页不改变正在运行的画面。
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace CallBridge.Windows;

internal sealed class VisualCatalogWindow : ModuleWindow
{
    private string _detail = "person", _background = "plate", _detailParent = "virtual";
    internal VisualCatalogWindow(App app, string route = "visual", string page = "home", string detail = "person", string background = "plate", string parent = "virtual") : base(app, route, "画面处理")
    {
        _detail = detail; _background = background; _detailParent = parent;
        ReturnHome = () => Host.Workspace.Back(this); Render(page, true);
    }
    internal void Navigate(string page, bool pairing = false)
    {
        if (page == CurrentPage) Render(page, pairing);
        else Host.OpenVisualPage(this, page, pairing, _detail, _background, _detailParent);
    }
    internal void Render(string page, bool pairing)
    {
        if (page == "backgrounds") Host.Visuals.EnterBackgrounds(pairing);
        UIElement body;
        var actions = new List<Button>();
        switch (page)
        {
            case "people":
                body = UI.Tiles(UI.Tile("虚拟人物形象替换", "\uE77B", () => Navigate("virtual")), UI.Tile("真实人物形象替换", "\uE77B", () => Navigate("real")), UI.Tile("待添加", "\uE710", () => { }, false)); break;
            case "virtual":
                body = UI.Tiles(UI.Tile("澄 · 通话装", "\uE77B", () => { Host.Visuals.SelectPerson(null); Detail("person", "virtual"); }), UI.Tile("导入 VRM", "\uE8B7", ImportCharacter), UI.Tile("待添加", "\uE710", () => { }, false)); break;
            case "real":
                body = UI.Tiles(UI.Tile("待添加", "\uE710", () => { }, false)); break;
            case "backgrounds":
                body = UI.Tiles(UI.Tile("静态背景", "\uE91B", () => Detail("plate", "backgrounds")), UI.Tile("动态背景", "\uE714", () => Navigate("dynamic", true)), UI.Tile("真实背景动态化", "\uE722", () => Detail("original", "backgrounds")), UI.Tile("待添加", "\uE710", () => { }, false)); break;
            case "dynamic":
                body = UI.Tiles(UI.Tile("流光", "\uE714", () => Detail("sample", "dynamic")), UI.Tile("窗景", "\uE81E", () => Detail("parallax", "dynamic")), UI.Tile("自定义素材", "\uE8B7", () => Detail("custom", "dynamic")), UI.Tile("图片背景", "\uE91B", () => Detail("image", "dynamic"))); break;
            case "detail":
                var background = _detail == "background";
                var title = background ? BackgroundName(_background) : Host.Visuals.CharacterPath == null ? "澄 · 通话装" : Path.GetFileNameWithoutExtension(Host.Visuals.CharacterPath);
                var column = UI.Column();
                var previewFile = Path.Combine(AppContext.BaseDirectory, "avatar", "preview.jpg");
                if (!background && Host.Visuals.CharacterPath == null && File.Exists(previewFile))
                    column.Children.Add(new Image { Source = new BitmapImage(new Uri(previewFile)), Height = 108, Stretch = Stretch.Uniform, Margin = new Thickness(0, 0, 0, 8) });
                column.Children.Add(UI.Hero(title, ResourcesReady() ? "资源已就绪 · 尚未打开" : "运行资源缺失"));
                if (background && _background is "custom" or "image") column.Children.Add(UI.Button(Host.Visuals.BackgroundPath == null ? "导入背景素材…" : "已导入 · 重新选择…", ImportBackground));
                column.Children.Add(UI.Label(background ? "同时替换人物？" : "同时替换背景？", true));
                column.Children.Add(UI.Row(UI.Button(background ? "选择人物…" : "选择背景…", () => { if (SelectDetail()) Navigate(background ? "people" : "backgrounds", true); }), UI.Button("不需要", () => { Host.Visuals.DeclinePartner(background); Message(background ? "人物不替换" : "背景不替换"); })));
                body = column; actions.Add(UI.Button("打开", async () => await Open(), ResourcesReady())); break;
            default:
                page = "home"; body = UI.Tiles(UI.Tile("人物形象替换", "\uE77B", () => Navigate("people")), UI.Tile("背景替换", "\uE91B", () => Navigate("backgrounds")), UI.Tile("云端服务", "\uE753", () => Host.OpenServices(this))); break;
        }
        Title = page switch { "home" => "画面处理", "people" => "人物形象替换", "virtual" => "虚拟人物", "real" => "真实人物", "backgrounds" => "背景替换", "dynamic" => "动态背景", _ => _detail == "person" ? "人物详情" : BackgroundName(_background) };
        ShowPage(page, page switch { "people" => "人物形象替换", "virtual" => "虚拟人物形象替换", "real" => "真实人物形象替换", "backgrounds" => "背景替换", "dynamic" => "动态背景", _ => "" }, body, actions.ToArray());
    }
    private bool ResourcesReady()
    {
        var root = AppContext.BaseDirectory;
        var required = new[] { "avatar/index.html", "avatar/app.js", "avatar/assets.json", "avatar/model/sample.vrm", "runtime/node.exe", "avatar-host/server.mjs", "camera/callbridge-camera-sender.exe" };
        return required.All(file => File.Exists(Path.Combine(root, file))) && (Host.Visuals.CharacterPath == null || File.Exists(Host.Visuals.CharacterPath));
    }
    internal static string BackgroundName(string kind) => kind switch { "original" => "真实背景 · 实时", "plate" => "采集静态背景", "sample" => "流光 · 视频素材", "parallax" => "窗景 · 2.5D", "custom" => "自定义素材", "image" => "图片背景", _ => kind };
    private void Detail(string kind, string parent)
    {
        _detail = kind == "person" ? "person" : "background"; if (_detail == "background") _background = kind;
        _detailParent = parent; Navigate("detail", true);
    }
    private bool SelectDetail()
    {
        try
        {
            if (_detail == "background") Host.Visuals.SelectBackground(_background, Host.Visuals.BackgroundPath);
            else Host.Visuals.SelectPerson(Host.Visuals.CharacterPath);
            return true;
        }
        catch (Exception e) { Message(e.Message); return false; }
    }
    private void ImportCharacter()
    {
        var picker = new OpenFileDialog { Filter = "VRM 角色|*.vrm", CheckFileExists = true };
        if (picker.ShowDialog(this) != true) return;
        if (!ValidFile(picker.FileName)) return;
        Host.Visuals.SelectPerson(picker.FileName); Detail("person", "virtual");
    }
    private bool ValidFile(string path)
    {
        var length = new FileInfo(path).Length;
        if (length <= 0 || length > 64 * 1024 * 1024) { Message("请选择 64 MiB 以内的本地素材"); return false; }
        return true;
    }
    private void ImportBackground()
    {
        var picker = new OpenFileDialog { Filter = _background == "image" ? "背景图片|*.png;*.jpg;*.jpeg" : "背景视频|*.mp4;*.webm;*.mov", CheckFileExists = true };
        if (picker.ShowDialog(this) != true || !ValidFile(picker.FileName)) return;
        Host.Visuals.BackgroundPath = picker.FileName; Navigate("detail", true); Message("已导入 · 未打开");
    }
    private async Task Open()
    {
        if (!SelectDetail()) return;
        Host.VisualPanel ??= new VisualWindow(Host, Host.MainPanel);
        Host.Workspace.Show("visual-runtime", this);
        await Host.VisualPanel.OpenAsync(Host.Visuals.Snapshot());
    }
}
