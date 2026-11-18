# CallBridge 使用说明 / Get started

[中文](#中文使用流程) · [English](#install-the-app)

Test release **0.0.4 (build 50)** targets **macOS 26+ on Apple Silicon** and **Windows 11 x64**.

**Hear your first sentence on Windows.** Download the Windows ZIP from [v0.0.4](https://github.com/storyon403-afk/CallBridge/releases/tag/v0.0.4), extract the entire folder, and open `CallBridge.exe`. In **音频模拟 → 输出设备 → 本机试听**, select your headphones or speakers. Open **文字输入**, type a sentence, expand **⌄**, and click **试听这段**. Leave **允许向所选设备发送** unchecked. Local preview does not require OBS, a virtual audio cable, or a call.

To send speech into a call later, select the virtual cable’s **playback** endpoint under **通话输出** and its paired **recording** endpoint as the call app’s microphone. Keep headphones selected for local preview. If the app fails to open, run `Test-Windows.cmd` in the extracted folder and keep `windows-check.log`. See the [portable guide](rust/windows/PORTABLE.md) and [Windows feature scope](rust/windows/README.md). Windows updates are manual. The instructions below cover macOS.

## Install the App

Download `CallBridge-0.0.4-macos-arm64.zip` from [Releases](https://github.com/storyon403-afk/CallBridge/releases). Unzip it and move `CallBridge.app` to Applications, then double-click to open it. The ZIP includes the video runtime; you do not need to install Node.js separately.

The App is not Apple signed or notarized. If macOS blocks the first launch, open **System Settings → Privacy & Security** and review the message for CallBridge. Use **Open Anyway** only if you trust the download. Do not turn off system security protections. If the App is reported as damaged, download a fresh copy and compare its checksum with `SHA256SUMS`.

Optional voice models, a virtual audio device, and OBS are separate downloads. Start with a system voice and the preview button before setting up a call.

Downloaded releases install verified updates when you quit; reopen to use the new version. See [Automatic updates](#automatic-updates). For the first upgrade from 0.0.2 or earlier, quit with **⌘Q** and replace the App manually.

## Text bar and windows

Open **Text input** from the main panel or the menu-bar icon. Type your message, then click the small arrow on the right to show **Preview text**, volume, **Allow sending**, and the other speech controls. The send and stop icons remain visible when settings are hidden.

- Drag the six-dot handle on the left, the title bar, or the empty area outside the input to move the window. Dragging text selects it.
- Drag an edge to change its size. Keep shrinking and release to turn it into a floating widget. Double-click the widget to restore your draft and panel.
- In the main panel, choose **Solid background** or **Translucent background**. The choice is saved. The system's Reduce Transparency setting takes priority.
- Use the CallBridge menu to choose **简体中文**, **English**, or **日本語**; quit and reopen for the language change.
- **⌘↩** sends, **⌘.** stops, and Enter adds a line. Confirm input-method candidates before sending.

## Audio

1. Open **Voice** and choose a system voice or an installed voice plugin.
2. In **Output device**, choose speakers or headphones for preview. Type a message, expand the text-bar settings, and click **Preview text**.
3. For a call, install [BlackHole 2ch](https://existential.audio/blackhole/) separately, or use an already installed supported device. Choose the same device in CallBridge and as the microphone in your call app. BlackHole 2ch and 16ch are different devices.
4. Keep the call app's speaker output on headphones or physical speakers. If it has no microphone menu, choose the virtual input in macOS Sound settings before starting the call.
5. Enable **Allow sending**, then click the send icon or press **⌘↩**. Use **Stop** to stop all audio.

The default CallBridge Microphone target needs the separate CallBridge Link driver. If it is not installed, choose an installed BlackHole target instead; the App does not switch devices for you.

For a hold-to-record voice message, click **Prepare**, enable sending, switch to the chat app and hold its record button, then press **Control–Option–Command–P** to play. **Control–Option–Command–.** stops. You can also use **Play in 5 s** to leave time to switch apps.

In **Audio mix**, import a WAV file for background sound and turn on playback when ready. Enable the environment track only when you want to include the real microphone. Each track has its own volume.

## Video

1. Install [OBS Studio](https://obsproject.com/download) and allow its virtual camera when macOS asks.
2. Quit the OBS main application before using CallBridge's video output.
3. Open **Video effects**, install the video engine if needed, and choose a character or background. Choose **Keep real person** when you only want to replace the background.
4. Open the preview. Enable the camera only when you want motion tracking or the real camera picture.
5. Start video output, then choose **OBS Virtual Camera** in the call app.

Keep the video window visible while using it. Closing it, hiding the App, or putting the Mac to sleep stops capture and output. Imported video backgrounds play without sound. The separately signed CallBridge Camera extension is an alternative for developers; use OBS for these instructions.

## Plugins

Open **Official plugins** from Voice → Audio plugins, Audio mix → Background file, or the character/background list. Choose **Refresh list → Download → Use**. An item marked **Coming soon** cannot be downloaded yet. Existing speech and video engines have their own download buttons.

To import a package you already have, click **Import local plugin…**, choose its folder, `.cbplugin`, or `.zip` file, then select the installed item. Downloading or importing does not start playback or the camera. See [plugin instructions](https://github.com/storyon403-afk/CallBridge/blob/main/plugins/official/README.md).

0.0.4 is a pre-release: install it manually from [v0.0.4](https://github.com/storyon403-afk/CallBridge/releases/tag/v0.0.4). The stable update feed remains on 0.0.3 until a newer stable build is published. Windows device and real-call acceptance for this build is pending.

## Automatic updates

Downloaded releases check GitHub for updates every 24 hours while CallBridge is running. Updates are downloaded and signature-verified in the background, then installed when you quit; reopen to use the new version. If the App is closed or the Mac is asleep/offline, checking resumes when it is running and online again. There is no separate background service.

Use **Check for Updates…** in the CallBridge or menu bar menu to check immediately. **Automatically Check and Install Updates** disables or enables future automatic checks and downloads; an update already prepared may still install on quit. System authorization may be needed when the App is not writable. Settings and installed plugins remain in Application Support; drafts still end with the session.

Version 0.0.2 and earlier require one manual replacement with an updater-enabled release. Source builds do not update themselves.

## Build from source

Install Xcode Command Line Tools, Rust/Cargo 1.88 or later, Node.js 22 or later, npm, and Python 3.12 or later. Use `xcode-select --install` for Apple's tools, [rustup](https://rustup.rs/) for Rust, and [Node.js](https://nodejs.org/en/download) for Node.

```sh
git clone https://github.com/storyon403-afk/CallBridge.git
cd CallBridge
cargo fetch --locked --manifest-path rust/Cargo.toml
cargo fetch --locked --manifest-path rust/pocket/Cargo.toml
sh rust/scripts/avatar-lab.sh prepare
python3 scripts/prepare-sparkle.py
sh rust/scripts/build-app.sh
```

Open `rust/build/app/CallBridge.app`. After updating the source, build again, quit the running App, and reopen it. This does not install virtual audio or camera devices.

## Global commands (one-time setup)

Already configured? Use `cb` and `cbt` from any directory; skip this setup. Check with `command -v cb` and `command -v cbt`.

For a new source checkout, run from the repository root. This creates small launchers in `~/.local/bin` and leaves existing `cb` / `cbt` commands unchanged.

```sh
python3 - <<'PY'
from pathlib import Path
import shlex

repo = Path.cwd().resolve()
assert (repo / 'CB').is_file() and (repo / 'CBT').is_file(), 'Run in the repository root'
bin_dir = Path.home() / '.local/bin'
bin_dir.mkdir(parents=True, exist_ok=True)
for name, target in [('cb', 'CB'), ('cbt', 'CBT')]:
    output = bin_dir / name
    if output.exists() or output.is_symlink():
        print(f'Already exists; keep unchanged: {output}')
        continue
    with output.open('x') as file:
        file.write('#!/bin/sh\nexec ' + shlex.quote(str(repo / target)) + ' "$@"\n')
    output.chmod(0o755)
PY
```

Add this line once to `~/.zshrc` if `~/.local/bin` is not already on PATH, then open a new terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Start from any directory:

```sh
cb
cbt
```

If you move the checkout, update your wrapper paths. `./CB` and `./CBT` are the repository scripts used by these commands, not the everyday launch commands.

## 中文使用流程

### 安装和更新

0.0.4（build 50）是测试版，需从 [v0.0.4](https://github.com/storyon403-afk/CallBridge/releases/tag/v0.0.4) 手动下载。稳定版自动更新仍保留 0.0.3；新版 Windows 真机与通话验收尚待完成。

**Windows：先听到第一句话。** 下载 Windows ZIP，完整解压后打开 `CallBridge.exe`。在「音频模拟 → 输出设备 → 本机试听」选自己的耳机或扬声器。回到「文字输入」，写一句话，点 **⌄ → 试听这段**。保持「允许向所选设备发送」未勾选即可；本机试听不需要 OBS、虚拟音频线或通话软件。

需要在通话中使用时，再把「通话输出」设为虚拟音频线的**播放端**，把通话软件的麦克风设为同一条线配对的**录音端**；本机试听仍用耳机。如果程序打不开，在解压目录双击 `Test-Windows.cmd`，保留生成的 `windows-check.log`。参见 [Windows 便携包说明](rust/windows/PORTABLE.md)及[功能范围](rust/windows/README.md)。Windows 版暂不支持自动更新，升级时退出旧版，完整解压新版后运行。以下步骤适用于 macOS。

到 [Releases](https://github.com/storyon403-afk/CallBridge/releases) 下载 `CallBridge-0.0.4-macos-arm64.zip`，解压，把 `CallBridge.app` 拖进“应用程序”，双击打开。需要 Apple Silicon Mac 和 macOS 26 或更新版本，安装包已带画面运行环境，不必另外安装 Node.js。

App 尚未经过苹果发布签名和公证。如果第一次打开被拦截，到“系统设置 → 隐私与安全性”查看 CallBridge 的提示；确认信任下载来源后再点“仍要打开”。不要关闭系统安全保护。如果提示文件损坏，请重新下载，并与 `SHA256SUMS` 中的校验码对照。

下载的发行版在运行时每 24 小时向 GitHub 检查更新，后台下载并验证签名，退出时自动安装，下次打开使用新版。应用未运行、电脑睡眠或断网时，等恢复运行和联网后再继续检查，不安装额外常驻服务。菜单中的“检查更新…”可立即检查，“自动检查并安装更新”可关闭后续自动检查和下载；已经准备好的更新仍可能在退出时安装。安装位置不可写时，系统可能要求授权。音色、设备设置和已安装插件保留；输入框草稿只保留到本次退出。

0.0.2 及更早版本需要先手动替换一次才能获得自动更新：按 **⌘Q** 退出，再替换 App 并重新打开。源码构建不自动更新。

如果想自己构建，先安装上方 [Build from source](#build-from-source) 列出的工具，再依次执行那里的命令。需要 `cb`、`cbt` 命令时，按 [Global commands](#global-commands-one-time-setup) 配置一次。

### 输入框怎么用

打开“文字输入”，输入想说的话。点右侧小箭头，展开试听、音量和“允许发送”等设置。发送和停止图标始终在输入框右侧。

拖左侧六点把手、标题栏或输入框外的空白处可以移动窗口；拖文字仍然是选字。拖边缘调整大小，继续拖小并松手就变成悬浮小组件，双击恢复。主面板可以切换实色／半透明背景。

在 CallBridge 菜单选择中文、英文或日文，退出再打开生效。**⌘↩ 发送，⌘. 停止，Enter 换行**。

### 让对方听见声音

1. 在“音频模拟”选择音色。先用系统音色，不用先下载模型。
2. 在“输出设备”选择试听用的扬声器或耳机；输入文字，点小箭头，再点“试听这段”。
3. 另外安装 [BlackHole 2ch](https://existential.audio/blackhole/) 等支持的虚拟音频设备。CallBridge 的发送目标和通话软件的麦克风都选同一个设备；2ch 和 16ch 不要混选。
4. 通话软件的扬声器继续选耳机或实际扬声器。没有麦克风菜单时，先在 macOS 声音设置选择虚拟输入，再开始通话。
5. 勾选“允许发送”，点击输入框右侧发送图标。结束时点“停止”。

默认的 CallBridge Microphone 需要另装 CallBridge Link 驱动。如果没有装，请在发送目标里改选已安装的 BlackHole，App 不会自动帮你换设备。

发按住录音的聊天语音时，先“准备语音”并允许发送，再切到聊天软件按住录音，按 **⌃⌥⌘P** 播放、**⌃⌥⌘.** 停止；也可选“5 秒后播放”，给自己留出切换时间。

“混音设置”可以导入 WAV 背景音，导入后点播放才会响。想混入真实麦克风时再开启环境音，每条音轨可以单独调音量。

### 让对方看见画面

安装 [OBS Studio](https://obsproject.com/download)，按系统提示允许它的虚拟摄像头，然后退出 OBS 主程序。打开 CallBridge 的“画面处理”，按需安装画面引擎，选择人物或背景，打开预览。需要跟随本人动作或使用现场画面时，再开启摄像头。

点“开始视频输出”，在通话软件选择 **OBS Virtual Camera**。使用中保持画面窗口可见；关闭画面窗口、隐藏 App 或电脑睡眠会停止采集和输出。只想换背景时选择“不替换人物”。视频背景不会播放素材里的声音。

### 换插件

从音频插件、文件背景详情或人物／背景列表进入“官方插件”，点“刷新列表 → 下载 → 使用”。显示“待发布”的项目暂时不能下载。已有插件包可以用“导入本地插件…”导入。详细入口见[插件说明](https://github.com/storyon403-afk/CallBridge/blob/main/plugins/official/README.md)。

### 没声音时先看这几处

先确认试听设备是扬声器或耳机，再确认已勾选允许发送。通话软件和 CallBridge 必须选同一个虚拟设备；检查人声音量没有调到 0，通话软件也没有静音。设备刚重新连接时，去音频设置刷新并重新选择。

画面没出来时，先退出 OBS 主程序，确认 CallBridge 已开始视频输出，再检查通话软件选的是 OBS Virtual Camera。
