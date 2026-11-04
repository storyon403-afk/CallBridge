// Windows 系统语音只写内存；显式发送才解析端点 UID 并启动 WASAPI。Rust 是播放状态的唯一来源。
using System.IO;
using System.Speech.AudioFormat;
using System.Speech.Synthesis;
using System.Text;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace CallBridge.Windows;

internal record OutputDevice(string Id, string Name) { public override string ToString() => Name; }

internal sealed class AudioController
{
    private Session _session;
    private CancellationTokenSource? _cancellation;
    private Task _operation = Task.CompletedTask;
    private PlayerHandle? _player;
    private WasapiOut? _output;
    private float[]? _prepared;
    private string? _preparedText;
    private string? _preparedVoice;
    internal float[]? Background;
    internal bool BackgroundLoop;
    internal float BackgroundGain = .25f;
    internal float Gain = .8f;
    internal event Action<string>? Status;
    internal string LastStatus { get; private set; } = "就绪 · 未发送";
    internal void Report(string text) { LastStatus = text; Status?.Invoke(text); }
    internal static OutputDevice[] InputDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        var result = new List<OutputDevice>();
        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            using (device) result.Add(new(device.ID, device.FriendlyName));
        return result.ToArray();
    }
    private bool _preparing;
    internal bool CountingDown => _session.State == 4 && _prepared != null;
    internal bool BeginCountdown() => Prepared && Core.cb_session_countdown(ref _session, _session.Generation) == 0;
    internal void CancelCountdown() { if (CountingDown) Core.cb_session_wait_prepared(ref _session, _session.Generation); }
    internal void DraftChanged()
    {
        if (_preparing || Prepared || CountingDown) { Invalidate(); _cancellation?.Cancel(); Report("文字已修改 · 请重新准备"); }
        else ClearPrepared();
    }
    internal bool Busy => !_operation.IsCompleted;
    internal bool Prepared => _session.State == 3 && _prepared != null;

    internal static OutputDevice[] Devices()
    {
        using var enumerator = new MMDeviceEnumerator();
        var devices = new List<OutputDevice>();
        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            using (device) devices.Add(new(device.ID, device.FriendlyName));
        }
        return devices.ToArray();
    }
    internal static string[] Voices()
    {
        using var synth = new SpeechSynthesizer();
        return synth.GetInstalledVoices().Where(v => v.Enabled).Select(v => v.VoiceInfo.Name).ToArray();
    }
    internal void SetGain(float gain)
    {
        Gain = Math.Clamp(gain, 0, 1);
        if (_player is { IsClosed: false }) Core.cb_player_set_gain(_player, Gain);
    }
    internal Task PrepareAsync(string text, string? voice)
    {
        EnsureIdle();
        Invalidate();
        Begin(text); _preparing = true;
        _cancellation?.Dispose(); _cancellation = new();
        return _operation = PrepareCoreAsync(text, voice, _session.Generation, _cancellation.Token);
    }
    private async Task PrepareCoreAsync(string text, string? voice, ulong generation, CancellationToken token)
    {
        try
        {
            Report("正在合成…");
            var pcm = await SynthesizeAsync(text, voice, token);
            token.ThrowIfCancellationRequested();
            if (Core.cb_session_prepared(ref _session, generation) != 0) return;
            _prepared = pcm; _preparedText = text; _preparedVoice = voice;
            Report("已备好 · 未发送");
        }
        catch (OperationCanceledException) { Report("已停止"); }
        catch (Exception e) { Invalidate(); Report("合成失败：" + e.Message); }
        finally { _preparing = false; }
    }
    internal Task SpeakAsync(string text, string? voice, string? endpointId, bool preview, bool permission)
    {
        EnsureIdle();
        if (!preview && !permission) throw new InvalidOperationException("请先允许向所选设备发送");
        if (string.IsNullOrWhiteSpace(endpointId)) throw new InvalidOperationException("请先选择输出设备");
        var usePrepared = Prepared && _preparedText == text && _preparedVoice == voice;
        if (!usePrepared) { Invalidate(); Begin(text); }
        _cancellation?.Dispose(); _cancellation = new();
        return _operation = SpeakCoreAsync(text, voice, endpointId, preview, usePrepared, _session.Generation, _cancellation.Token);
    }
    private void Begin(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        if (Core.cb_session_begin(ref _session, bytes, (uint)bytes.Length) != 0)
            throw new InvalidOperationException("请输入 1–280 个字符");
    }
    private void EnsureIdle()
    {
        if (Busy) throw new InvalidOperationException("请先停止当前任务");
        if (_output != null || _player != null) throw new InvalidOperationException("前次设备清理未完成，请停止并重启应用");
    }
    private async Task SpeakCoreAsync(string text, string? voice, string id, bool preview, bool prepared, ulong generation, CancellationToken token)
    {
        MMDeviceEnumerator? enumerator = null;
        MMDevice? device = null;
        try
        {
            Report(prepared ? "正在连接设备…" : "正在合成…");
            var pcm = prepared ? _prepared! : await SynthesizeAsync(text, voice, token);
            token.ThrowIfCancellationRequested();
            var transition = prepared ? Core.cb_session_play_prepared(ref _session, generation) : Core.cb_session_ready(ref _session, generation);
            if (transition != 0) return;
            // 每次按稳定 ID 重新解析；没有 GetDefaultAudioEndpoint，也不因拔插替换设备。
            enumerator = new MMDeviceEnumerator();
            device = enumerator.GetDevice(id);
            if (device.State != DeviceState.Active || device.DataFlow != DataFlow.Render)
                throw new InvalidOperationException("所选输出设备不可用");
            _player = new(Core.cb_player_create(pcm, (uint)pcm.Length, 4800));
            if (_player.IsInvalid) throw new InvalidOperationException("PCM 校验失败或超过 30 秒");
            Core.cb_player_set_gain(_player, Gain);
            if (!preview && !prepared && Background is { Length: > 0 } background &&
                Core.cb_player_set_background(_player, background, (uint)background.Length, BackgroundLoop ? 1u : 0u, BackgroundGain) != 0)
                throw new InvalidOperationException("背景音频配置失败");
            var provider = new RustWaveProvider(_player);
            // 固定核心时间基为 48 kHz；不让库在实时循环里隐式创建重采样处理链。
            if (!device.AudioClient.IsFormatSupported(AudioClientShareMode.Shared, provider.WaveFormat))
                throw new InvalidOperationException("输出设备不支持 48 kHz 双声道 Float32 共享模式，请在 Windows 声音设置检查设备格式");
            _output = new WasapiOut(device, AudioClientShareMode.Shared, true, 50);
            var completed = new TaskCompletionSource<Exception?>(TaskCreationOptions.RunContinuationsAsynchronously);
            _output.PlaybackStopped += (_, e) => completed.TrySetResult(e.Exception);
            _output.Init(provider);
            token.ThrowIfCancellationRequested();
            Report(preview ? "本机试听中" : "发送中");
            _output.Play();
            var error = await completed.Task;
            if (error != null) throw error;
            token.ThrowIfCancellationRequested();
            if (provider.Error != 0 || Core.cb_player_done(_player) == 0)
                throw new InvalidOperationException("输出中断，未正常播放完成");
            if (preview && prepared && _prepared != null) Core.cb_session_preview_finished(ref _session, generation);
            else { Core.cb_session_finish(ref _session, generation); ClearPrepared(); }
            Report(preview ? (prepared && _prepared != null ? "试听结束 · 仍可发送" : "试听结束") : "本地播放完成");
        }
        catch (OperationCanceledException) { Report("已停止"); }
        catch (Exception e) { Invalidate(); Report("音频失败：" + e.Message); }
        finally
        {
            // WasapiOut.Dispose/Stop 会等待其播放线程退出；之后才能释放被 Read 借用的 Rust 对象。
            // 清理抛错时保留 _player，不伪装成释放成功。
            _output?.Dispose(); _output = null;
            _player?.Dispose(); _player = null;
            device?.Dispose(); enumerator?.Dispose();
        }
    }
    internal async Task StopAsync()
    {
        Invalidate();
        _cancellation?.Cancel();
        if (_player is { IsClosed: false }) Core.cb_player_cancel(_player);
        // Stop 等待 WASAPI 线程，不在音频回调内等待 UI；PlaybackStopped 再完成上面的 await。
        _output?.Stop();
        await _operation;
        Report("已停止");
    }
    private void ClearPrepared() { _prepared = null; _preparedText = null; _preparedVoice = null; }
    private void Invalidate() { Core.cb_session_cancel(ref _session); ClearPrepared(); }

    private static async Task<float[]> SynthesizeAsync(string text, string? voice, CancellationToken token)
    {
        // 系统 TTS 的回调只交付内存 PCM，不接触默认扬声器或麦克风。
        using var synth = new SpeechSynthesizer();
        using var pcm = new BoundedPcmStream();
        if (!string.IsNullOrWhiteSpace(voice)) synth.SelectVoice(voice);
        synth.SetOutputToAudioStream(pcm, new SpeechAudioFormatInfo(48000, AudioBitsPerSample.Sixteen, AudioChannel.Mono));
        var finished = new TaskCompletionSource<SpeakCompletedEventArgs>(TaskCreationOptions.RunContinuationsAsynchronously);
        synth.SpeakCompleted += (_, args) => finished.TrySetResult(args);
        token.ThrowIfCancellationRequested();
        synth.SpeakAsync(text);
        using var registration = token.Register(synth.SpeakAsyncCancelAll);
        var result = await finished.Task;
        token.ThrowIfCancellationRequested();
        if (result.Error != null) throw result.Error;
        if (result.Cancelled) throw new OperationCanceledException(token);
        if (pcm.Length == 0 || pcm.Length % 2 != 0) throw new InvalidDataException("系统语音未返回有效 PCM");
        var bytes = pcm.ToArray();
        var samples = new float[bytes.Length / 2];
        for (var i = 0; i < samples.Length; i++)
            samples[i] = Math.Clamp(BitConverter.ToInt16(bytes, i * 2) / 32768f, -.9999695f, .9999695f);
        return samples;
    }
    internal static float[] LoadBackground(string file)
    {
        using var reader = new AudioFileReader(file);
        if (reader.TotalTime.TotalSeconds > 30) throw new InvalidDataException("背景素材最多 30 秒，可启用循环");
        ISampleProvider provider = reader;
        if (provider.WaveFormat.Channels == 2) provider = new StereoToMonoSampleProvider(provider);
        else if (provider.WaveFormat.Channels != 1) throw new InvalidDataException("背景素材须为单声道或双声道");
        if (provider.WaveFormat.SampleRate != 48000) provider = new WdlResamplingSampleProvider(provider, 48000);
        var pcm = new List<float>(); var buffer = new float[4096]; int read;
        while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
        {
            if (pcm.Count + read > 1_440_000) throw new InvalidDataException("背景素材超过 30 秒");
            for (var i = 0; i < read; i++)
            {
                if (!float.IsFinite(buffer[i])) throw new InvalidDataException("背景音频样本无效");
                pcm.Add(Math.Clamp(buffer[i], -.9999695f, .9999695f));
            }
        }
        if (pcm.Count == 0) throw new InvalidDataException("背景素材为空");
        return pcm.ToArray();
    }
}

