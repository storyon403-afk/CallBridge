# CallBridge 0.0.4 · 正式版 / Stable release

**Windows 11 x64：** 下载[带图标的 Windows 便携包](https://github.com/storyon403-afk/CallBridge/releases/download/v0.0.4/CallBridge-0.0.4-windows-x64-icons1.zip)，完整解压后打开 `CallBridge.exe`。也可先运行 `Test-Windows.cmd`。用 `WINDOWS-icons1-SHA256SUMS` 核对这份 ZIP。它补齐了资源管理器、窗口、任务栏和托盘的品牌图标。原始 Windows ZIP 继续保留；两包除应用 EXE、DLL 和包清单外，文件内容一致。图标修订的[确切源码](https://github.com/storyon403-afk/CallBridge/commit/a53506a53a3003e9b7f589a031b45fc328798a91)。

**macOS 26+ · Apple Silicon：** [下载 Mac 版](https://github.com/storyon403-afk/CallBridge/releases/download/v0.0.4/CallBridge-0.0.4-macos-arm64.zip)，或在支持自动更新的发行版中选择「检查更新」。0.0.2 及更早版本请手动升级。Mac 包仍是 build 50，沿用已签名的更新源与 ZIP。

本版改善 Windows 文字面板、输出设备提示、模块导航和 OBS 画面转换。macOS 增加实验性的 CBFA v1 二维帧角色支持；实验人物素材不随包提供。

**实测范围（2026-11-19）：** Windows 11 x64 → 独立 Mac WebRTC 对端，通过 VB-Audio 传送系统语音，通过 OBS Virtual Camera 传送测试画面；Mac 解码出非零语音和三种不同的测试色。macOS 上使用 Sparkle 将单独解压的 0.0.3 在线升级至 0.0.4，核对安装后的文件和签名并通过界面自检。测试网络曾出现 GitHub TLS 连接失败，重试后成功。未验证所有第三方通话软件、网络或设备组合。

Windows 仍需手动更新；驱动、OBS 和部分可选运行时需独立安装。Windows 包无发布者签名，Mac 包未做 Apple Developer ID 签名或公证。

**English:** Version 0.0.4 is the stable release. Windows users should choose the `windows-x64-icons1.zip` portable package and its separate checksum file. The macOS ZIP and signed Sparkle feed are unchanged. An independent Mac WebRTC peer received speech from VB-Audio and changing video from OBS Virtual Camera. Sparkle upgraded an extracted 0.0.3 app online to build 50; the installed files matched the published app. This does not establish compatibility with every call client. Windows publisher signing and Apple distribution signing/notarization are not provided.

The original archives, checksums, tag and attached notes are retained as build-time records. This release page describes the final publication and the supplemental Windows package.
