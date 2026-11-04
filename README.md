<p align="center"><img src="icon/icon.png" width="112" alt="CallBridge"></p>
<h1 align="center">CallBridge</h1>
<p align="center">Type it. Say it. Join the call.</p>
<p align="center">English · <a href="README.zh-CN.md">简体中文</a> · <a href="https://storyon403-afk.github.io/CallBridge/">See it in action ↗</a></p>

CallBridge brings typed speech, voices, background audio and virtual characters into your calls through virtual audio and video devices.

**0.0.3 · macOS 26+ (Apple Silicon) · Windows 11 x64**

Windows has a portable package for system speech, file mixing and virtual-character video. Pocket/personal voices, plugin installation, persistent ambience, cloud operations and automatic updates remain macOS-only. See [Windows installation and scope](rust/windows/README.md).

## Features

- **Speech & voices** — System TTS, Pocket, personal voices, preview and prepared speech.
- **Audio mixing** — Speech, background files and live ambience with independent volume controls.
- **Virtual characters** — Cheng · Call Outfit, VRM characters, image/video backgrounds and OBS Virtual Camera output.
- **Voice input settings** — Microphone selection, separate preview devices, voice and output controls.
- **Cloud services** — Provider catalog, account configuration, guides and FASHN image try-on jobs.
- **Plugins** — Official catalog, local package import, voice effects, characters and backgrounds.
- **App updates** — Release builds check daily, verify signed downloads and install on quit.

The cloud catalog includes **Decart Lucy, LiveAvatar, Tavus CVI, FASHN, ZEGO, Xmov, HeyGen Video and Synthesia**.

## Get started

1. Download your platform package from [Releases](https://github.com/storyon403-afk/CallBridge/releases). On Mac, move the App to Applications; on Windows, fully extract the ZIP and open `CallBridge.exe`.
2. Choose a system voice, open **Text input**, and preview your message.
3. Configure a [virtual microphone](GETTING_STARTED.md#audio) for call audio or [OBS Virtual Camera](GETTING_STARTED.md#video) for video.

Mac: **⌘↩** Send · **⌘.** Stop. Windows: **Ctrl+Enter** Send · **Ctrl+.** Stop. **Enter** adds a new line.

Resizable panels and floating widgets stay beside your call. The macOS edition offers solid or translucent panels and Chinese, English or Japanese menus.

[Installation & usage](GETTING_STARTED.md) · [Build from source](GETTING_STARTED.md#build-from-source) · [Windows 11 x64 guide](rust/windows/README.md) · [Plugin guide](插件接入教程.md)

## License

[PolyForm Noncommercial 1.0.0](LICENSE) permits personal and other allowed noncommercial use. Third-party components retain their own licenses. See [license details](LICENSING.md).

UI inspiration: [ftop](https://github.com/Nongfsq/ftop).
