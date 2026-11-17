# CallBridge 0.0.4 测试版

Build 50 · macOS 26+（Apple Silicon）· Windows 11 x64

这是供手动安装和回归的 Pre-release。0.0.3 仍是稳定版，现有稳定版用户不会自动收到本测试版。

## 本版更新

- Windows 文字面板改善中文两行显示、展开后的编辑区域与光标位置保留。
- Windows 文字面板直接显示发送目标，提示设备不可用及试听/发送设备重复，提供设备设置入口。
- Windows 模块补充返回入口、无障碍按钮名称和未支持功能说明；人物详情与 VRM 导入入口更清楚。
- Windows OBS 适配将最终 RGBA 画面转换为连续 RGB 数据，避免向不支持 RGBA 的后端提交错误格式。
- macOS 新增实验性 CBFA v1 二维帧角色导入、图集校验与渲染，支持有限转头、眨眼、说话、微笑和皱眉状态。二维图集不能替代完整 3D 身体、手指或任意角度跟踪。
- 更新中英文安装、测试与平台范围说明。实验人物素材和未发布角色插件不随包提供；保留内置「澄 · 通话装」。

## 下载与安装

| 平台 | 下载文件 | 安装 |
| --- | --- | --- |
| macOS 26+ · Apple Silicon | `CallBridge-0.0.4-macos-arm64.zip` | 退出旧版，解压后把 App 拖进“应用程序” |
| Windows 11 x64 | `CallBridge-0.0.4-windows-x64.zip` | 完整解压，先运行 `Test-Windows.cmd`，再打开 `CallBridge.exe` |
| 源码 | `CallBridge-0.0.4-source.tar.gz` | 两个平台源码、构建入口与许可说明 |

使用 `SHA256SUMS` 核对下载文件。Windows 包自带 .NET、Node、Python 和视频适配依赖；画面窗口需要另装 Microsoft WebView2 Runtime。虚拟音频驱动、OBS、语音模型及私人资源不随包提供。

## 测试范围与已知限制

本版从当前源码重新构建，不复用 0.0.3 ui2 的 Windows 程序。旧版的真机确认不代表本版通过验收。Windows 真机界面、虚拟设备、实际通话与 macOS 在线升级仍需回归；自动化检查和交叉编译不能替代这些检查。包内 `UI-ACCEPTANCE.md` 提供 Windows 回归清单。

Windows 尚未提供 Pocket/个人音色、插件安装、常驻环境混音、多语言、全局快捷键、云端任务和自动更新。macOS 实时变声和识别引擎尚未提供，云端媒体传输/合成与真实账号验收尚未完成。

macOS 包保留已签名更新校验，后续稳定版发布后可检查更新。本测试版不会替换 GitHub 的 latest 稳定更新源。0.0.2 及更早版本需要手动安装；Windows 升级始终手动下载完整包。

macOS 尚未使用 Apple Developer ID 签名或公证，Windows 未做发布者签名。更新签名不等于 Apple 公证，首次启动可能出现系统提示。参见[安装说明](https://github.com/storyon403-afk/CallBridge/blob/v0.0.4/GETTING_STARTED.md)与 [Windows 范围](https://github.com/storyon403-afk/CallBridge/blob/v0.0.4/rust/windows/README.md)。

## English

CallBridge 0.0.4 (build 50) is a manual-install pre-release for macOS 26+ Apple Silicon and Windows 11 x64. Version 0.0.3 remains the stable automatic-update release.

This build improves Windows text layout, route warnings, navigation and accessibility, fixes OBS RGBA-to-RGB conversion, and adds experimental CBFA v1 frame-avatar validation and rendering on macOS. Experimental artwork and unpublished character packages are excluded; Cheng · Call Outfit remains available.

The Windows package is rebuilt from current source. Previous ui2 acceptance does not cover this build. Windows UI/device/real-call acceptance and a live macOS upgrade remain pending. See the packaged Windows checklist. Windows features and platform limitations remain as documented in the linked guides.

Fully extract the Windows ZIP and run `Test-Windows.cmd` before launching `CallBridge.exe`. Compare downloads with `SHA256SUMS`. WebView2, OBS and virtual audio drivers remain separate prerequisites. Apple Developer ID signing/notarization and Windows publisher signing are not provided.
