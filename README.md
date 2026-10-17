<h1 align="center">CallBridge</h1> 

视频通话时发挥你的想象。

 视频通话辅助工具：通过虚拟麦克风传递合成语音，通过虚拟摄像头传递处理后的画面。通话软件继续负责通话，CallBridge 负责你想让对方听见和看见的内容。

[技术图解](graph.md) · [构建](#构建) · [使用](#使用) · [开发](#开发)

> [!WARNING]
> **声明：**
> 以下所有叙述均不能代表该demo日后的实际设计，只是概念展示，用于该idea解释

## 一个窗口，控制声音与形象

输入文字、选择声音、点击发送。不需要对着麦克风讲话，也不需要向 FaceTime 或微信注入代码。UI 采用原生 AppKit（目前本demo针对macos），ui交互会参考 [ftop](https://github.com/Nongfsq/ftop) 的轻量面板。

## 产品设计

| 模块 | 设计 |
| --- | --- |
| 文字语音 | 男声、女声与可扩展音色；发送、停止、音量调节；本地个性化音色。 |
| 现场背景 | 合成语音叠加明确授权的麦克风输入；环境声与真实人声都会进入。 |
| 自定义背景 | 导入本地音频；独立控制音量，讲话时压低背景，结束后恢复。 |
| Cartoon 替身 | 用角色与合成背景替换真人画面；嘴部跟随实际播放的语音，也可不启用摄像头。 |
| 视频背景 | 人物分割与背景合成，支持标准背景和本地图片。 |
| 资源扩展 | 统一管理音色、音频效果、角色、动画和背景插件；声明兼容版本、权限与许可。 |

## 构建

本机音频演示 App 的构建要求：Apple Silicon、macOS 26+、Apple Command Line Tools、Rust，以及callbridge 虚拟音频引擎 （先前计划的[BlackHole 16ch/2ch](https://github.com/ExistentialAudio/BlackHole)经实测未知bug不可行,待以后详细探索）。设备设为 48 kHz，系统安装 Tingting 或 Samantha 语音。

在项目根目录运行：

```sh
./CB build
./CB
```

也可双击 `rust/build/app/CallBridge.app`。在当前终端执行 `export PATH="$PWD:$PATH"` 后，可直接用 `CB` 启动；不需要修改系统目录。

构建脚本离线编译并进行本地 ad-hoc 签名；不安装音频驱动，不更改系统默认设备，不生成公证发行包。

目前正在学习和必要测试，以下所有将在该demo实际可展示和使用后提供。

## 使用



## 边界



## 开发
[demo进度](schedule.md)

## 参考

[ftop：README 以及后来ui参考](https://github.com/Nongfsq/ftop) · [Apple：Core Audio 数据流](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/ARoadmaptoCommonTasks/ARoadmaptoCommonTasks.html) · [BlackHole：应用间音频回环](https://github.com/ExistentialAudio/BlackHole)
