# CallBridge 0.0.5 · build 51

macOS 和 Windows 的主窗口现在都从「我的通话组合」开始。

- 在「组合台」搭配人物和画面背景，再打开画面预览。Windows 提供「澄 · 通话装」「落日海岸」「窗边晨光」，也可从素材库进入本地人物和背景选择。
- 在「接线台」检查声音输出与本机试听设备。从主窗口的「打字说话」进入文字面板，发送仍需单独授权。
- Windows 的画面输出使用 OBS Virtual Camera，系统音色和文件混音沿用现有 Windows 引擎。

## 下载

| 平台 | 文件 | 使用方式 |
| --- | --- | --- |
| Windows 11 x64 | `CallBridge-0.0.5-windows-x64.zip` | 完整解压，双击 `CallBridge.exe`。包内提供 `Test-Windows.cmd`。 |
| Apple Silicon · macOS 26 或更高版本 | `CallBridge-0.0.5-macos-arm64.zip` | 解压，将 `CallBridge.app` 移至「应用程序」。 |

校验值见同目录的 `SHA256SUMS`。Windows 包没有发布者签名，macOS 包使用 ad-hoc 签名，未做 Apple Developer ID 签名或公证。macOS 自动更新使用独立的 Sparkle 签名。

**English.** Both desktop apps now open to the call studio. Compose an avatar and backdrop in Studio, choose audio devices in Routing, and open Type to Speak to prepare or send speech. Extract the complete Windows ZIP before opening CallBridge.exe. Windows publisher signing and macOS Developer ID signing and notarization are not provided.
