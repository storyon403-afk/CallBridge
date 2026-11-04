// Rust 拥有 PCM、进度与代次；这里仅声明固定宽度 ABI，SafeHandle 防止在渲染调用中释放。
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CallBridge.Windows;

[StructLayout(LayoutKind.Sequential)]
internal struct Session { public ulong Generation; public uint State; }

internal sealed class PlayerHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public PlayerHandle() : base(true) { }
    internal PlayerHandle(IntPtr pointer) : base(true) => SetHandle(pointer);
    protected override bool ReleaseHandle() { Core.cb_player_destroy(handle); return true; }
}

internal static unsafe class Core
{
    private const string Library = "callbridge_abi_probe";
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int cb_session_begin(ref Session session, byte[] text, uint bytes);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int cb_session_ready(ref Session session, ulong generation);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int cb_session_prepared(ref Session session, ulong generation);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int cb_session_countdown(ref Session session, ulong generation);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int cb_session_wait_prepared(ref Session session, ulong generation);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int cb_session_play_prepared(ref Session session, ulong generation);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int cb_session_preview_finished(ref Session session, ulong generation);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int cb_session_finish(ref Session session, ulong generation);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void cb_session_cancel(ref Session session);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr cb_player_create(float[] pcm, uint frames, uint drainFrames);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int cb_player_render(PlayerHandle player, float* output, uint capacity, uint frames, uint channels);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void cb_player_cancel(PlayerHandle player);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern uint cb_player_done(PlayerHandle player);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern uint cb_player_position(PlayerHandle player);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int cb_player_set_gain(PlayerHandle player, float gain);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int cb_player_set_background(PlayerHandle player, float[] pcm, uint frames, uint loop, float gain);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void cb_player_destroy(IntPtr player);
}
