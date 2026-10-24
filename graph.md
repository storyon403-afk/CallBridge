# CallBridge 技术图解

对应 0.10.1。图中实线表示当前实现，虚线表示仍需签名安装的自有摄像头路线；客户端是否收到须独立验证。

```mermaid
flowchart TB
    UI[AppKit 面板 · cb / cbt]
    UI --> T[系统 TTS / 可选 Pocket · 个人音色]
    UI --> B[持续文件背景 / 授权麦克风环境]
    T --> M[Rust 有界缓冲 · 增益 · 混音]
    B --> M
    M --> A[输出专用 AUHAL]
    A --> L[CallBridge Link → CallBridge Microphone]
    L --> C[通话软件]

    UI --> C0[画面处理 · 人物 / 背景]
    C0 --> P[人物选择 · 不替换 / 澄 · 通话装]
    C0 --> BG[背景选择 · 原背景 / 采集静态 / 视频 / 2.5D]
    P --> W[打开后加载 WKWebView / 本机 Node 服务]
    W --> H[Holistic → KalidoKit → Three.js / VRM]
    H --> F[人物前景 + 背景 → 最终画布]
    BG --> F
    F --> S[有界帧桥 / 原生发送器]
    S --> O[已安装的 OBS Virtual Camera]
    O --> C
    S -. 团队签名安装后待验证 .-> X[CallBridge Camera Extension]
    X -.-> C
```

TTS、环境音和文件背景独立控制；背景不等待语句播放。形象资源按需安装，安装完成后另行打开。TTS 口型、通用背景/角色导入尚未接入。具体边界见 [架构](docs/VIDEO_CALL_DESIGN.md)。

## 普通通话的声音路径

这张图解释麦克风到远端的基础过程；CallBridge 的纯 TTS 模式从数字合成开始，不经过物理麦克风。

![声音的一次旅行](assets/diagrams/01-audio-lifecycle.png)
