# Windows 11 x64

Windows 桌面迁移使用 WPF + WebView2，保留 Rust 音频/会话核心和现有 Cheng · Call Outfit 画面模块。0.0.3 提供 Windows 11 x64 便携发行包和构建源码；macOS 安装包不能用于 Windows。

## 便携发行包

直接运行请看 [Windows 便携包说明](PORTABLE.md)。`CallBridge-0.0.3-windows-x64.zip` 已包含 Windows 程序、Rust DLL、.NET、Node 与视频适配运行时，完整解压后运行 `Test-Windows.cmd`，再打开 `CallBridge.exe`。发行包基于已由维护者确认通过 Windows 测试的 ui2 程序整理。

维护者可用 `sh rust/scripts/build-windows-cross.sh` 复用 `rust/build/toolchains/` 中的 .NET 10.0.403、Rust 1.97.1（含 Windows gnullvm 目标）和 LLVM-MinGW 20261020，在 Apple Silicon Mac 上重新组装。运行时归档由 `release/windows-runtime.json` 固定；传入 `--restore` 才会下载缺失归档。

## 当前范围

| 功能 | Windows 源码状态 |
| --- | --- |
| 主面板、文字、音频模拟、混音、画面处理、声音转录 | 复用当前 Mac 入口/概要/详情层级；标准面板 400×360，文字 560×112/360 |
| 收起标签、返回父页、独立置顶、托盘 | 已接入；视觉目录逐层单实例，运行画面保持展开；多屏自动避让/过渡动画待适配 |
| 系统 TTS、准备语音、5 秒倒计时、独立设备试听、发送、停止、音量 | 已接入 System.Speech → Rust → 指定 WASAPI 端点 |
| 文件背景混音 | 可导入最多 30 秒素材，随文字发送混入；可循环；配置下次发送生效 |
| Cheng、导入 VRM、图片/视频背景、相机驱动与动作演示 | 复用现有本地画面模块，由 WebView2 承载 |
| 最终合成画面 → OBS Virtual Camera | 独立 Python/pyvirtualcam 进程；固定 1280×720 RGBA；30 fps 是目标，未实测 |
| 设备丢失、取消、隐藏/最小化/锁屏/睡眠、进程退出 | 失败不换设备；会话不自动恢复；子进程使用 Windows Job 绑定宿主 |
| Pocket/个人音色、插件管理器、独立常驻环境音/背景音、多语言、全局快捷键、云服务远端操作、自动更新 | 尚未迁移；不能视为与 macOS 完整功能对齐 |

Windows 版已实现音视频桌面主流程，**尚未与 macOS 完整功能对齐**；差异见上表。Apple TTS 预设与 macOS 插件包不会被误认成 Windows 插件。

## 构建前提

- Windows 11 x64，PowerShell 7。
- Visual Studio Build Tools 的 C++ 工具与 Windows SDK，Rust MSVC 工具链（Rust ≥1.85）。
- .NET 10 SDK、Node.js 22+ x64、Python 3.11+ x64。
- WebView2 Evergreen Runtime，启动 GUI 时需要。安装由使用者执行，构建脚本不安装。
- 已按 [avatar 说明](../avatar/README.md)准备并校验 `rust/build/avatar-assets/` 的资源。脚本不下载模型。
- 启用实际音频发送时，需要自行安装合适的虚拟音频线；启用视频时，需要自行安装 OBS Virtual Camera。二者都不随源码构建安装，不修改系统默认设备。

在仓库根目录执行：

```powershell
# 首次明确恢复 Cargo/NuGet/npm/Python 构建依赖；不下载角色模型或安装驱动。
.\rust\scripts\build-windows.ps1 -Restore

# 依赖已准备后离线复用；缺失缓存会报错。
.\rust\scripts\build-windows.ps1

# 仅在要启动应用时执行。
.\CB.ps1

# 启动并打开文字面板。
.\CBT.ps1
```

完整构建目录：`rust/build/windows/app/`，主程序：`CallBridge.exe`。保留整个目录；不要只复制 exe。构建脚本运行无设备检查，不启动应用、不执行 TTS、不采集或发送。

`rust/build/windows/cross-compiled/`（如果在 macOS 运行了交叉编译）只是 .NET 编译产物，**缺少 Windows Rust DLL、摄像头适配包与完整资源，不能当作完整安装包**。

## 操作

1. 打开“音频模拟 → 输出设备”，选择 Windows 系统音色、虚拟音频线的**播放端**以及独立的扬声器/耳机试听端。通话软件选择该虚拟线配对的**录音端**。设备名称相似时以 Windows 音频配置为准。
2. 文字窗口可以先“准备语音”或“试听这段”。发送前展开并勾选“允许向所选设备发送”，再点“发送”。每次选择设备/音色后授权会撤销，关闭文字窗口保留本次进程草稿，但撤销授权；重启不恢复授权或草稿。准备好后可用“5 秒后播放”，需切换到其他程序；留在 CallBridge、超时或撤权不会自动播出。
3. 当前 WASAPI 适配要求所选端点支持 48 kHz 双声道 Float32 共享模式。缺失、不兼容或被占用时直接报错，不改系统格式或默认设备。
4. “混音设置 → 文件背景”导入文件只加载；下次直接发送文字时混入，准备语音路径保持纯语音。真实环境详情允许选择设备，采集和独立常驻播放仍待适配。
5. “画面处理”先浏览人物/背景目录，详情中明确点击“打开”才启动画面；可导入 VRM 或背景。返回目录保留运行画面，目录选择不会改动运行快照。开启摄像头与开始视频输出是两个独立动作。OBS 主程序不能同时占用虚拟摄像头输出；通话软件选择 **OBS Virtual Camera**。
6. 文字关闭停止音频。画面关闭、隐藏、最小化、锁屏或睡眠停止采集和输出；重新打开后需主动启动。真实设备断开后不自动重连。

文字窗口内 `Ctrl+Enter` 发送，`Ctrl+.` 停止，`Enter` 换行；不会拦截输入法组字确认。当前入口每次启动一个新进程，尚未加入跨进程窗口唤起。

个人设置和 WebView2 数据位于 `%LOCALAPPDATA%\CallBridge\`。输出状态、发送授权、准备 PCM 不持久化。相机不接触音频输入。

界面对照清单见 [Windows UI 验收](UI-ACCEPTANCE.md)。声音转录与云服务提供导航和能力状态；Windows 尚无变声/识别引擎或云端任务适配，相关动作禁用。

## 构建检查与设备要求

可无设备执行：

```powershell
cargo fmt --manifest-path rust/Cargo.toml -- --check
cargo test --offline --manifest-path rust/Cargo.toml
dotnet run --project rust/windows/CallBridge.CoreChecks -- rust/target/x86_64-pc-windows-msvc/release/callbridge_abi_probe.dll
python -m unittest discover -s rust/windows/camera -p 'test_*.py' -v
```

便携发行包使用交叉编译产物，维护者已确认 ui2 在 Windows 测试通过；这不代表所有设备、客户端或以下每个场景均已覆盖。MSVC/PyInstaller 构建路径需单独验证。后续版本可按以下范围回归：

- 首次启动、WebView2/声音缺失、DPI/中文输入法、键盘焦点、窗口缩放。
- 系统 TTS 内存合成、物理试听与虚拟发送隔离；停止/撤权/拔插后无旧声音重播。
- VRM/背景加载、相机许可、独立音视频同时运行、窗口关闭/最小化/锁屏/睡眠清理。
- OBS 设备占用/停止/断开/超时的占位画面；实际通话客户端接收和长时间稳定性。

驱动安装、媒体采集/发送、回环、真实通话均由使用者在明确授权后执行。参见 [Windows 依赖与许可边界](THIRD_PARTY.md)。
