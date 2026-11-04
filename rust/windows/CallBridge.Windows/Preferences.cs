// 只保存用户选择，不保存草稿、发送授权、准备 PCM 或正在采集的状态。
using System.IO;
using System.Text.Json;

namespace CallBridge.Windows;

internal sealed class Preferences
{
    public string? OutputId { get; set; }
    public string? PreviewId { get; set; }
    public string? Voice { get; set; }
    public double Gain { get; set; } = .8;
    public bool Translucent { get; set; }
    public string? MicrophoneId { get; set; }
    public string RecognitionLanguage { get; set; } = "自动识别";
    internal static string DataDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CallBridge");
    private static string FileName => Path.Combine(DataDirectory, "windows-settings.json");
    internal static Preferences Load()
    {
        try
        {
            if (!File.Exists(FileName) || new FileInfo(FileName).Length > 16384) return new();
            var value = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(FileName)) ?? new();
            if (!double.IsFinite(value.Gain) || value.Gain < 0 || value.Gain > 1) value.Gain = .8;
            return value;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }
    internal void Save()
    {
        Directory.CreateDirectory(DataDirectory);
        var temp = FileName + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(this));
        File.Move(temp, FileName, true);
    }
}
