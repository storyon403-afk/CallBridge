# CallBridge 0.0.3

## 下载与安装

| 平台 | 下载文件 | 安装 |
| --- | --- | --- |
| macOS 26+ · Apple Silicon | `CallBridge-0.0.3-macos-arm64.zip` | 退出旧版，解压后把 App 拖进“应用程序” |
| Windows 11 x64 | `CallBridge-0.0.3-windows-x64.zip` | 完整解压，运行 `CallBridge.exe`；可先运行 `Test-Windows.cmd` 检查组件 |
| 源码 | `CallBridge-0.0.3-source.tar.gz` | 包含两个平台的源码、构建入口和许可说明 |

使用 `SHA256SUMS` 核对下载文件。音频驱动、OBS、语音模型和私人资源不随包提供。Windows 包自带 .NET、Node、Python 与视频适配依赖；画面窗口需要 Microsoft WebView2 Runtime。

## 本版功能

- Windows 11 x64 便携版：系统 TTS、准备语音、独立试听/发送、文件混音、WPF 面板及虚拟人物画面输出。发行程序沿用维护者已确认通过 Windows 测试的 ui2 版本。
- macOS 云端服务目录、账号配置和厂商指南，支持 FASHN 图片任务。
- macOS 声音转录设置面板，集中管理输入、试听设备与音色设置；实时变声和识别引擎尚未提供。
- macOS 官方插件目录与本地插件包导入。
- 更新中英文使用说明与项目主页。

Windows 尚未提供 Pocket/个人音色、插件安装、常驻环境混音、多语言、全局快捷键、云端任务和自动更新；升级时需手动下载完整新版。各平台的功能范围见[使用说明](https://github.com/storyon403-afk/CallBridge/blob/v0.0.3/GETTING_STARTED.md)与 [Windows 说明](https://github.com/storyon403-afk/CallBridge/blob/v0.0.3/rust/windows/README.md)。

## macOS 自动更新

- 发行版运行时每 24 小时检查 GitHub，后台下载并验证更新，退出时安装，下次打开生效。
- 应用菜单与菜单栏提供“检查更新…”和自动更新开关；未运行时不检查，不会为了更新强行退出通话。
- 更新包和更新清单均使用 Ed25519 签名验证，保留已有设置与插件。
- 0.0.2 及更早版本需先手动安装本版一次。源码构建不自动更新，安装位置不可写时可能需要系统授权。

macOS 包尚未使用 Apple Developer ID 签名或公证，Windows 便携包未做发布者签名。macOS 更新签名不等于 Apple 公证；首次启动可能显示系统提示。

## English

CallBridge 0.0.3 ships a macOS 26+ Apple Silicon App and a Windows 11 x64 portable ZIP. The Windows executable payload is preserved from ui2, which the maintainer confirmed passed Windows testing. Fully extract the Windows ZIP, optionally run `Test-Windows.cmd`, then launch `CallBridge.exe`. It bundles .NET, Node and Python; WebView2, virtual audio drivers and OBS remain separate prerequisites where needed.

Windows includes system speech, prepared speech, separate preview/sending devices, file mixing, WPF panels and virtual-character video output. Pocket/personal voices, plugin installation, persistent ambience, multiple UI languages, global shortcuts, cloud operations and automatic updates are not yet available on Windows.

macOS adds the cloud catalog/configuration/guides, FASHN image jobs and voice-input settings. Live voice conversion and recognition engines remain unavailable. macOS release builds check daily while running, verify signed updates and install on quit. Versions through 0.0.2 need one manual upgrade. Windows upgrades are manual.

Compare downloads with `SHA256SUMS`. macOS Developer ID signing/notarization and Windows publisher signing are not provided. See the linked installation guides for platform requirements and feature scope.
