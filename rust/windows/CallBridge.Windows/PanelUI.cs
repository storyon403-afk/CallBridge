// 统一概要卡片、详情导航与固定页脚；尺寸来自已确认的 Mac 面板，内容只在中部滚动。
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Automation;

namespace CallBridge.Windows;

internal static class UI
{
    internal static TextBlock Label(string text, bool caption = false) => new() { Text = text, Style = caption ? (Style)Application.Current.FindResource("Caption") : null, TextWrapping = TextWrapping.Wrap };
    internal static Button Button(string text, Action action, bool enabled = true, string? help = null)
    {
        var b = new Button { Content = text, IsEnabled = enabled, ToolTip = help, Margin = new Thickness(0, 0, 8, 0) };
        AutomationProperties.SetName(b, help ?? text); b.Click += (_, _) => action(); return b;
    }
    internal static Button Link(string title, string detail, Action action, bool enabled = true)
    {
        var grid = new Grid(); grid.ColumnDefinitions.Add(new()); grid.ColumnDefinitions.Add(new());
        var label = Label(title); label.VerticalAlignment = VerticalAlignment.Center;
        var value = Label(detail + "  ›", true); value.VerticalAlignment = VerticalAlignment.Center; value.TextWrapping = TextWrapping.NoWrap; value.TextTrimming = TextTrimming.CharacterEllipsis; value.HorizontalAlignment = HorizontalAlignment.Right; Grid.SetColumn(value, 1);
        grid.Children.Add(label); grid.Children.Add(value);
        var b = Button(title, action, enabled, detail); b.Content = grid; b.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        b.Background = Brushes.Transparent; b.Padding = new Thickness(4, 6, 4, 6); b.Margin = new Thickness(0); b.MinHeight = 32; return b;
    }
    internal static StackPanel Column(params UIElement[] children)
    {
        var p = new StackPanel(); foreach (var child in children) p.Children.Add(child); return p;
    }
    internal static WrapPanel Row(params UIElement[] children)
    {
        var p = new WrapPanel { Margin = new Thickness(0, 4, 0, 4) }; foreach (var child in children) p.Children.Add(child); return p;
    }
    internal static Grid GainRow(TextBlock label, Slider slider)
    {
        var row = new Grid(); row.ColumnDefinitions.Add(new() { Width = new GridLength(76) }); row.ColumnDefinitions.Add(new());
        label.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(slider, 1); row.Children.Add(label); row.Children.Add(slider); return row;
    }
    internal static Border Card(params UIElement[] children) => new() { Style = (Style)Application.Current.FindResource("Card"), Padding = new Thickness(10), Margin = new Thickness(0, 0, 0, 8), Child = Column(children) };
    internal static Border Hero(string title, string subtitle) => Card(new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap }, Label(subtitle, true));
    internal static ComboBox Select(string name)
    {
        var combo = new ComboBox(); AutomationProperties.SetName(combo, name); return combo;
    }
    internal static Button Tile(string title, string icon, Action action, bool enabled = true)
    {
        var stack = new StackPanel(); stack.Children.Add(new TextBlock { Text = icon, FontFamily = new FontFamily("Segoe Fluent Icons"), FontSize = 22, Margin = new Thickness(0, 0, 0, 8) });
        stack.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        var b = Button(title, action, enabled); b.Style = (Style)Application.Current.FindResource("Tile"); b.Content = stack; b.Height = 88; b.Margin = new Thickness(0); return b;
    }
    internal static Panel Tiles(params Button[] buttons)
    {
        var grid = new Grid();
        void Arrange(double width)
        {
            var columns = width < 308 ? 1 : 2;
            grid.ColumnDefinitions.Clear(); grid.RowDefinitions.Clear();
            for (var c = 0; c < columns; c++) grid.ColumnDefinitions.Add(new());
            for (var r = 0; r < (buttons.Length + columns - 1) / columns; r++) grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
            for (var i = 0; i < buttons.Length; i++)
            {
                Grid.SetRow(buttons[i], i / columns); Grid.SetColumn(buttons[i], i % columns);
                buttons[i].Height = columns == 1 ? 72 : 88;
                buttons[i].Margin = new Thickness(0, 0, columns == 2 && i % 2 == 0 ? 8 : 0, 8);
            }
        }
        foreach (var b in buttons) grid.Children.Add(b);
        grid.SizeChanged += (_, _) => Arrange(grid.ActualWidth); Arrange(368); return grid;
    }
}

public class ModuleWindow : Window
{
    internal readonly App Host;
    internal readonly string Route;
    internal readonly TextBlock StatusLabel = UI.Label("", true), Heading = UI.Label("");
    internal readonly Button BackButton;
    internal readonly ContentControl Page = new();
    internal readonly WrapPanel Actions = new() { HorizontalAlignment = HorizontalAlignment.Right };
    private readonly StackPanel _navigation;
    internal string CurrentPage { get; private set; } = "home";
    internal Action? ReturnHome;
    internal ModuleWindow(App app, string route, string title)
    {
        Host = app; Route = route; Title = title; Width = 400; Height = 360; MinWidth = 180; MinHeight = 96;
        Style = (Style)app.FindResource(typeof(Window));
        var root = new DockPanel { Margin = new Thickness(16, 4, 16, 10) };
        BackButton = UI.Button("‹ 返回", () => { if (CurrentPage != "home" && ReturnHome != null) ReturnHome(); else app.Workspace.Back(this); });
        _navigation = UI.Column(UI.Row(BackButton, Heading)); DockPanel.SetDock(_navigation, Dock.Top); root.Children.Add(_navigation);
        var footer = new Grid { MinHeight = 40 }; footer.ColumnDefinitions.Add(new()); footer.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        Grid.SetColumn(Actions, 1); Actions.MaxWidth = 215; footer.Children.Add(StatusLabel); footer.Children.Add(Actions);
        StatusLabel.VerticalAlignment = VerticalAlignment.Center; Actions.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        StatusLabel.MaxHeight = 30; StatusLabel.Margin = new Thickness(0, 4, 0, 4);
        root.Children.Add(new ScrollViewer { Content = Page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }); Content = root;
        app.Workspace.Register(route, this);
        Closing += (_, e) => { if (app.Exiting) return; e.Cancel = true; app.Workspace.Dismiss(this); };
    }
    internal void ShowPage(string key, string title, UIElement body, params Button[] actions)
    {
        CurrentPage = key; Heading.Text = title; Page.Content = body;
        _navigation.Visibility = key == "home" ? Visibility.Collapsed : Visibility.Visible;
        Actions.Children.Clear(); foreach (var action in actions) { action.Margin = new Thickness(8, 4, 0, 0); Actions.Children.Add(action); }
    }
    internal void Message(string text) { StatusLabel.Text = text; StatusLabel.ToolTip = text; }
}
