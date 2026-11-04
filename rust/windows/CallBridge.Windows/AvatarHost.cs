// WebView2 只访问随机端口的本机资源服务；私有 stdin 与 Windows Job 绑定子进程生命期。
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace CallBridge.Windows;

internal sealed class AvatarHost : IAsyncDisposable
{
    private Process? _process;
    private ProcessJob? _job;
    internal Uri? Origin { get; private set; }
    internal async Task<Uri> StartAsync(string? background, string? character, CancellationToken token)
    {
        var root = AppContext.BaseDirectory;
        var node = Path.Combine(root, "runtime", "node.exe");
        var server = Path.Combine(root, "avatar-host", "server.mjs");
        var sender = Path.Combine(root, "camera", "callbridge-camera-sender.exe");
        foreach (var file in new[] { node, server, sender, Path.Combine(root, "avatar", "index.html") })
            if (!File.Exists(file)) throw new FileNotFoundException("Windows 运行资源不完整，请重新执行构建脚本", file);
        var info = new ProcessStartInfo(node)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = root
        };
        info.ArgumentList.Add(server); info.ArgumentList.Add("--app-host");
        info.Environment["CB_AVATAR_PORT"] = "0";
        info.Environment["CB_AVATAR_ASSETS"] = Path.Combine(root, "avatar");
        info.Environment["CB_AVATAR_CAMERA"] = "obs";
        info.Environment["CB_AVATAR_SENDER"] = sender;
        // 防止继承开发 shell 的素材或检测开关；导入必须来自这次明确选择。
        foreach (var key in new[] { "CB_AVATAR_PLUGIN", "CB_BACKGROUND_FILE", "CB_CHARACTER_FILE", "CB_CHARACTER_SHA", "CB_CHARACTER_BYTES", "CB_CORE_LIBRARY" }) info.Environment.Remove(key);
        if (background != null) info.Environment["CB_BACKGROUND_FILE"] = background;
        if (character != null)
        {
            var file = new FileInfo(character);
            if (file.Length < 24 || file.Length > 64 * 1024 * 1024) throw new InvalidDataException("VRM 文件大小无效");
            using var stream = File.OpenRead(character);
            info.Environment["CB_CHARACTER_FILE"] = character;
            info.Environment["CB_CHARACTER_BYTES"] = file.Length.ToString(System.Globalization.CultureInfo.InvariantCulture);
            info.Environment["CB_CHARACTER_SHA"] = Convert.ToHexString(await System.Security.Cryptography.SHA256.HashDataAsync(stream, token)).ToLowerInvariant();
        }
        _job = new ProcessJob();
        _process = Process.Start(info) ?? throw new IOException("无法启动视觉资源服务");
        _job.Assign(_process);
        // 丢弃子进程 stderr，避免管道堵塞；完整诊断只通过受控状态接口进入界面。
        _process.ErrorDataReceived += (_, _) => { }; _process.BeginErrorReadLine();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        var line = await _process.StandardOutput.ReadLineAsync(timeout.Token);
        if (line == null || line.Length > 1024) throw new IOException("视觉资源服务启动失败");
        using var data = JsonDocument.Parse(line);
        var port = data.RootElement.GetProperty("port").GetInt32();
        if (port < 1 || port > 65535) throw new IOException("视觉服务端口无效");
        Origin = new Uri($"http://127.0.0.1:{port}/");
        return Origin;
    }
    public async ValueTask DisposeAsync()
    {
        Origin = null;
        if (_process != null)
        {
            try
            {
                if (!_process.HasExited)
                {
                    _process.StandardInput.Close();
                    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(4));
                    try { await _process.WaitForExitAsync(timeout.Token); }
                    catch (OperationCanceledException) { _job?.Dispose(); await _process.WaitForExitAsync(); }
                }
            }
            finally { _process.Dispose(); _process = null; _job?.Dispose(); _job = null; }
        }
        else { _job?.Dispose(); _job = null; }
    }
}

internal sealed class ProcessJob : SafeHandleZeroOrMinusOneIsInvalid
{
    // KILL_ON_JOB_CLOSE 确保宿主崩溃后 node 与摄像头子进程不会继续输出。
    internal ProcessJob() : base(true)
    {
        SetHandle(CreateJobObject(IntPtr.Zero, null));
        if (IsInvalid) throw new System.ComponentModel.Win32Exception();
        var limits = new ExtendedLimits(); limits.Basic.LimitFlags = 0x2000;
        if (!SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>()))
        { Dispose(); throw new System.ComponentModel.Win32Exception(); }
    }
    internal void Assign(Process process)
    {
        if (AssignProcessToJobObject(handle, process.Handle)) return;
        try { process.Kill(true); } finally { throw new System.ComponentModel.Win32Exception(); }
    }
    protected override bool ReleaseHandle() => CloseHandle(handle);
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimits
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters
    { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits
    {
        public BasicLimits Basic; public IoCounters Io;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits data, uint bytes);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
}
