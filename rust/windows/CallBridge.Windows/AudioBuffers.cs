// PCM 容量和渲染边界与设备适配分离，便于在无 Windows 设备时验证真实 Rust ABI。
using System.IO;
using NAudio.Wave;

namespace CallBridge.Windows;

internal sealed class BoundedPcmStream : MemoryStream
{
    private const long Limit = 48000 * 30 * 2;
    public override void Write(byte[] buffer, int offset, int count)
    {
        if (Position + count > Limit) throw new IOException("合成语音超过 30 秒");
        base.Write(buffer, offset, count);
    }
    public override void Write(ReadOnlySpan<byte> buffer)
    {
        if (Position + buffer.Length > Limit) throw new IOException("合成语音超过 30 秒");
        base.Write(buffer);
    }
    public override void SetLength(long value)
    {
        if (value > Limit) throw new IOException("合成缓冲超过上限");
        base.SetLength(value);
    }
    public override void WriteByte(byte value)
    {
        if (Position >= Limit) throw new IOException("合成缓冲超过上限");
        base.WriteByte(value);
    }
}

internal sealed unsafe class RustWaveProvider(PlayerHandle player) : IWaveProvider
{
    public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(48000, 2);
    internal int Error;
    public int Read(byte[] buffer, int offset, int count)
    {
        // 回调仅做有界内存处理；不分配、不写日志、不操作 UI。错误缓冲清零再结束。
        if (count < 0 || offset < 0 || offset > buffer.Length - count) return 0;
        if (count == 0) return 0;
        if (count % 8 != 0 || count > 16384 * 8) { Array.Clear(buffer, offset, count); Error = -1; return 0; }
        if (Core.cb_player_done(player) != 0) return 0;
        fixed (byte* ptr = &buffer[offset])
        {
            Error = Core.cb_player_render(player, (float*)ptr, (uint)count / 4, (uint)count / 8, 2);
        }
        if (Error == 0) return count;
        Array.Clear(buffer, offset, count); return 0;
    }
}
