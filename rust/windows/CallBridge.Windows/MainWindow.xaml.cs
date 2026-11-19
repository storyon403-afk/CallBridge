// 组合台编辑待用构图，只在显式打开时把快照交给运行窗口。接线仍由音频与文字面板管理。
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CallBridge.Windows;

public partial class MainWindow : Window
{
    private readonly App _app;
    private static readonly (string File, string Name)[] Scenes =
        [("coast-evening.jpg", "落日海岸"), ("window-morning.jpg", "窗边晨光")];
    private static string Art(string name) => Path.Combine(AppContext.BaseDirectory, "studio", name);

    internal MainWindow(App app)
    {
        _app = app;
        InitializeComponent();
        app.Workspace.Register("main", this);
        app.Audio.Gain = (float)app.Preferences.Gain;
        Material.IsChecked = app.Preferences.Translucent;
        Width = Math.Min(Width, SystemParameters.WorkArea.Width);
        Height = Math.Min(Height, Math.Max(MinHeight, SystemParameters.WorkArea.Height - 56));
        app.Visuals.SelectPerson(null);
        app.Visuals.SelectBackground("image", Art(Scenes[0].File));
        Portrait.Source = ReadImage("cheng.png");
        foreach (var (file, name) in Scenes)
        {
            var button = UI.Button(name, () => { app.Visuals.SelectBackground("image", Art(file)); RefreshBoard(); });
            button.Content = UI.Column(new Image { Source = ReadImage(file), Stretch = Stretch.UniformToFill, Height = 58 }, UI.Label(name));
            button.Width = 112; button.Margin = new Thickness(0, 0, 8, 8);
            Swatches.Children.Add(button);
        }
        LibraryActions.Content = UI.Column(
            UI.Link("澄 · 通话装", "内置形象", UseCheng),
            UI.Link("更多人物和背景", "导入素材", () => app.OpenVisualCatalog(this)),
            UI.Link("系统音色", "选择", () => app.OpenAudio(this, "voice")),
            UI.Link("文件背景音", "混音设置", () => app.OpenMixing(this)));
        app.Audio.Status += text => Status.Text = text;
        Views.SelectionChanged += (_, e) =>
        {
            if (ReferenceEquals(e.OriginalSource, Views) && Views.SelectedIndex == 1) RefreshRouting();
        };
        Activated += (_, _) => { RefreshBoard(); RefreshRouting(); };
        Closing += (_, e) => { if (app.Exiting) return; e.Cancel = true; app.Workspace.Dismiss(this); };
        RefreshBoard();
    }

    private static BitmapImage? ReadImage(string file)
    {
        var path = Art(file);
        return File.Exists(path) ? new BitmapImage(new Uri(path)) : null;
    }

    private void RefreshBoard()
    {
        var setup = _app.Visuals.Snapshot();
        var bundled = Scenes.FirstOrDefault(s => string.Equals(Art(s.File), setup.BackgroundPath, StringComparison.OrdinalIgnoreCase));
        var scene = bundled.Name ?? (setup.BackgroundPath == null ? VisualCatalogWindow.BackgroundName(setup.Background) : Path.GetFileName(setup.BackgroundPath));
        var actor = setup.Person == "avatar" ? (setup.CharacterPath == null ? "澄 · 通话装" : Path.GetFileNameWithoutExtension(setup.CharacterPath))
            : setup.BackgroundOnly ? "纯背景" : "真人 · 构图示意";
        // 外部素材仍在独立运行窗口解码；组合台只展示随包缩略图，避免误用默认人物顶替导入的模型。
        Backdrop.Source = bundled.File == null ? null : ReadImage(bundled.File);
        Portrait.Visibility = setup.Person == "avatar" && setup.CharacterPath == null ? Visibility.Visible : Visibility.Collapsed;
        Composition.Text = actor + "  ·  " + scene;
        AutomationProperties.SetName(Backdrop, scene);
        OpenPreview.IsEnabled = !setup.BackgroundOnly || setup.Background is not ("original" or "plate");
        var mix = _app.Workspace.Get("mixing") as MixingWindow;
        Slots.Content = UI.Column(
            UI.Link("音色", _app.Preferences.Voice ?? "系统默认音色", () => _app.OpenAudio(this, "voice")),
            UI.Link("背景音", mix?.FileName ?? "未选择", () => _app.OpenMixing(this)));
        Status.Text = _app.Audio.LastStatus;
    }

    private void RefreshRouting()
    {
        string Device(string? id, OutputDevice[] devices) => id == null ? "未选择" : devices.FirstOrDefault(d => d.Id == id)?.Name ?? "设备不可用";
        Status.Text = _app.Audio.LastStatus;
        OutputDevice[] devices = [];
        try { devices = AudioController.Devices(); } catch (Exception e) { Status.Text = "无法读取输出设备：" + e.Message; }
        Routing.Content = UI.Column(
            UI.Card(UI.Link("通话输出", Device(_app.Preferences.OutputId, devices), () => _app.OpenAudio(this, "output")),
                UI.Link("本机试听", Device(_app.Preferences.PreviewId, devices), () => _app.OpenAudio(this, "output"))),
            UI.Card(UI.Link("画面预览", "OBS Virtual Camera", async () => await OpenVisual(), OpenPreview.IsEnabled)),
            UI.Card(UI.Link("混音设置", "文件背景音", () => _app.OpenMixing(this)),
                UI.Link("云服务", "离线指南", () => _app.OpenServices(this)),
                UI.Link("声音转录", "Windows 暂不支持", () => { }, false)));
    }

    private void BoardResized(object sender, SizeChangedEventArgs e)
    {
        var narrow = e.NewSize.Width < 670;
        Board.ColumnDefinitions[1].Width = narrow ? new GridLength(0) : new GridLength(2, GridUnitType.Star);
        Grid.SetColumn(Library, narrow ? 0 : 1);
        Grid.SetRow(Library, narrow ? 1 : 0);
        Library.Margin = narrow ? new Thickness(0, 10, 0, 0) : new Thickness(10, 0, 0, 0);
    }

    internal void Restore() => _app.Workspace.Show("main");
    internal void ShowText() => _app.OpenText(null);
    private void OpenText(object sender, RoutedEventArgs e) => ShowText();
    private void StopAll(object sender, RoutedEventArgs e) => _app.StopMedia();
    private void SelectAvatar(object sender, RoutedEventArgs e) => UseCheng();
    private void UseCheng() { _app.Visuals.SelectPerson(null); RefreshBoard(); }
    private void SelectCamera(object sender, RoutedEventArgs e) { _app.Visuals.SelectCamera(); RefreshBoard(); }
    private void SelectBackdropOnly(object sender, RoutedEventArgs e) { _app.Visuals.SelectBackdropOnly(); RefreshBoard(); }
    private async void Preview(object sender, RoutedEventArgs e) => await OpenVisual();

    private async Task OpenVisual()
    {
        _app.VisualPanel ??= new VisualWindow(_app, this);
        _app.Workspace.Show("visual-runtime", this);
        await _app.VisualPanel.OpenAsync(_app.Visuals.Snapshot());
    }

    private void MaterialChanged(object sender, RoutedEventArgs e)
    {
        _app.Preferences.Translucent = Material.IsChecked == true;
        Theme.UpdateMaterial();
        try { _app.Preferences.Save(); } catch (Exception error) { Status.Text = error.Message; }
    }
}
