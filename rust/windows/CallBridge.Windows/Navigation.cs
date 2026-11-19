// 页面结构对应当前 macOS 控制器；导航状态不拥有音频、采集或渲染资源。
using System.IO;

namespace CallBridge.Windows;

internal sealed class Navigation
{
    internal sealed class Entry(string id, string? parent, bool canFold)
    {
        internal string Id = id;
        internal string? Parent = parent;
        internal bool CanFold = canFold, Visible, Open;
    }
    internal Dictionary<string, Entry> Entries { get; } = new();
    internal void Register(string id, bool canFold = true) => Entries.TryAdd(id, new(id, null, canFold));
    internal void Show(string id, string? from = null)
    {
        var target = Entries[id]; target.Open = true; target.Visible = true;
        if (from == null || from == id || !Entries.TryGetValue(from, out var parent)) return;
        // 返回时不把祖先重新挂到后代，防止“主面板→文字→主面板”形成环。
        var cursor = parent;
        while (cursor.Parent != null && cursor.Parent != id && Entries.TryGetValue(cursor.Parent, out var next)) cursor = next;
        if (cursor.Parent != id) target.Parent = from;
        if (parent.CanFold && parent.Open) parent.Visible = false;
    }
    internal void Fold(string id) { var e = Entries[id]; if (e.Open && e.CanFold) e.Visible = false; }
    internal string? Back(string id)
    {
        var e = Entries[id];
        if (e.Parent is not { } parent || !Entries.ContainsKey(parent)) return null;
        if (e.CanFold) e.Visible = false;
        Show(parent); return parent;
    }
    internal void Unregister(string id)
    {
        if (!Entries.Remove(id, out var removed)) return;
        foreach (var child in Entries.Values.Where(e => e.Parent == id)) child.Parent = removed.Parent;
    }
    internal void Dismiss(string id) { Entries[id].Open = false; Entries[id].Visible = false; }
}

internal sealed record VisualSnapshot(string Person, string Background, string? CharacterPath, string? BackgroundPath, bool BackgroundOnly = false);
internal sealed class VisualSelection
{
    internal string Person = "none", Background = "original";
    internal bool BackgroundOnly { get; private set; }
    internal string? CharacterPath, BackgroundPath;
    internal void EnterBackgrounds(bool pairing) { if (!pairing) SelectCamera(); }
    internal void SelectPerson(string? path) { Person = "avatar"; CharacterPath = path; BackgroundOnly = false; }
    internal void SelectCamera() { Person = "none"; BackgroundOnly = false; }
    internal void SelectBackdropOnly() { Person = "none"; BackgroundOnly = true; }
    internal void SelectBackground(string kind, string? path = null)
    {
        if (!new[] { "original", "plate", "sample", "parallax", "custom", "image" }.Contains(kind)) throw new ArgumentException("未知背景");
        if (kind is "custom" or "image" && string.IsNullOrWhiteSpace(path)) throw new ArgumentException("请先导入背景素材");
        if (kind is "custom" or "image")
        {
            var extensions = kind == "image" ? new[] { ".png", ".jpg", ".jpeg" } : new[] { ".mp4", ".webm", ".mov" };
            if (!extensions.Contains(Path.GetExtension(path!).ToLowerInvariant())) throw new ArgumentException("素材格式与背景类型不匹配，请重新导入");
        }
        Background = kind; BackgroundPath = kind is "custom" or "image" ? path : null;
    }
    internal void DeclinePartner(bool backgroundDetail) { if (backgroundDetail) SelectCamera(); else { Background = "original"; BackgroundPath = null; } }
    internal VisualSnapshot Snapshot() => new(Person, Background, Person == "avatar" ? CharacterPath : null, BackgroundPath, BackgroundOnly);
}
