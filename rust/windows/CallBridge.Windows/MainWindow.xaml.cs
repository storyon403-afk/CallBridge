// 主面板只保留当前 Mac 的四个模块；帮助、退出和置顶由窗口/托盘菜单提供。
using System.Windows;
using System.Windows.Controls;

namespace CallBridge.Windows;

public partial class MainWindow : Window
{
    private readonly App _app;
    internal MainWindow(App app)
    {
        _app = app; InitializeComponent();
        app.Workspace.Register("main", this); app.Audio.Gain = (float)app.Preferences.Gain;
        Material.SelectedIndex = app.Preferences.Translucent ? 1 : 0;
        Modules.Content = UI.Tiles(
            UI.Tile("音频模拟", "\uE767", () => app.OpenAudio(this)),
            UI.Tile("混音设置", "\uE9E9", () => app.OpenMixing(this)),
            UI.Tile("画面处理", "\uE714", () => app.OpenVisualCatalog(this)),
            UI.Tile("声音转录", "\uE720", () => app.OpenTranscription(this), false, "Windows 暂不支持"));
        app.Audio.Status += text => { Status.Text = text; Status.ToolTip = text; };
        Closing += (_, e) => { if (app.Exiting) return; e.Cancel = true; app.Workspace.Dismiss(this); };
    }
    internal void Restore() => _app.Workspace.Show("main");
    internal void ShowText() => _app.OpenText(this);
    private void OpenText(object sender, RoutedEventArgs e) => ShowText();
    private void StopAll(object sender, RoutedEventArgs e) => _app.StopMedia();
    private void MaterialChanged(object sender, SelectionChangedEventArgs e)
    {
        _app.Preferences.Translucent = Material.SelectedIndex == 1; Theme.UpdateMaterial();
        try { _app.Preferences.Save(); } catch (Exception error) { Status.Text = error.Message; }
    }
}
