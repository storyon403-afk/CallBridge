# CallBridge 虚拟形象

复用 MediaPipe → KalidoKit → Three.js/VRM。0.10.1 以人物/背景独立目录和按需资源插件嵌入 CallBridge 的“画面处理”窗口，音频管线不变；尚不是通用第三方视频插件。

## 应用内使用

运行 `cb` → **画面处理**，先选 **人物形象替换 → 虚拟人物形象替换 → 澄 · 通话装**，或进入 **背景替换** 选择静态空背景、流光视频、窗景 2.5D、自定义视频。人物分类保留真实人物形象替换与待添加；真实人物替换尚未实现；真实背景动态化提供持续现场视频。

选择现有角色后先显示静态效果图，无需下载或开启模型；点击 **下载** 获取约 47.6 MB 资源；本机完整开发资源可复用时显示 **安装已有资源**。完成后显示 **已安装 / 打开**，已下载按钮禁用。点击 **打开** 后才加载形象和控制界面，不自动开启相机或发送。已安装插件每次打开检查摘要，损坏包提示错误，不覆盖或重复下载。

默认输出选择 **OBS Virtual Camera**，也可选择自有 **CallBridge Camera**（仍需签名安装）。应用自动管理本地服务，无需浏览器或单独运行 `cb avatar-obs`。

先点“动作演示”预览；真人跟踪由你点击“开启摄像头”并授权，实时现场背景直接与角色合成，无需离场；只有静态背景需要采集并确认。准备好后点“开始视频输出”，通话软件选同名设备。使用 OBS 时退出 OBS 主程序。保持画面窗口可见；关闭、最小化、隐藏应用、睡眠或退出会停止。重新打开/加载后不会恢复采集和发送授权。

设备选择与窗口位置随现有设置保存，空背景和相机帧只在会话内存中。仅进入效果详情才检查插件；点击下载才联网，下载中可取消，不打开摄像头或麦克风。

当前应用复用系统 WKWebView 和本机 Node.js 22+，后台 Node 由 App 管理；不捆绑 Chromium 或 Node 运行时。构建记录本机 Node 路径，另支持 Homebrew 常见安装位置。换电脑或移动 Node 后可能需要重建。主 App 约 4.9 MiB（磁盘占用），47,647,999 字节的模型/跟踪资源独立安装到 `~/Library/Application Support/CallBridge/Plugins/avatar-holistic-v1`，模型精度和纹理不变。构建不会自动安装用户插件。

```sh
sh rust/scripts/build-app.sh
# 真实 WebKit + 公开测试图 + 原生内存帧；不开音视频设备
rust/build/app/CallBridge.app/Contents/MacOS/CallBridge --avatar-ui-check
```

用户已确认此前网页/OBS 链路可用；应用内验证记录见[原生集成证据](../../docs/evidence/2026-10-23-avatar-panel.md)。新窗口的真人采集权限和第三方实际通话仍需使用确认。

## 背景与组合

人物、背景各自单选，可独立组合；详情快捷跳转保留当前选择，“不需要”关闭另一槽替换。选择与本地素材路径保存到设置，不恢复采集或输出许可。保留真人时不解析 VRM；真实背景模式直接绘制视频，不加载 Holistic 或等待分割。换成静态/素材背景时用同帧分割保留真人前景。所有现场采集请求均为 `audio:false`，不录制文件。

自定义视频支持系统可解码的 MP4/MOV/WebM，限制 64 MiB、120 秒、1920×1080。素材强制静音、循环，停止时暂停；文件不复制到插件目录。视频通过私有固定端点和有界 Range 读取，不接受请求传入任意本地路径。背景与人物共用已有资源包，完整安装不重复下载。具体行为见 [BackGround](../../BackGround.md)。

`backgrounds/aurora.mp4` 为本项目用 FFmpeg `gradients` 生成的 8 秒无音轨素材，66,193 字节。复现命令：

```sh
ffmpeg -f lavfi -i 'gradients=s=640x360:r=24:c0=0x182c48:c1=0x72b5b0:c2=0xe0b891:n=3:seed=12:d=8:speed=0.08:type=radial' -an -c:v libx264 -preset slow -crf 25 -pix_fmt yuv420p -movflags +faststart aurora.mp4
```

`src/background.mjs` 提供素材生命周期与程序化窗景，无新增模型。`scripts/check-backgrounds.mjs` 检查两个人物选项 × 五种背景的合成像素、过期遮罩、静音循环、停止及素材路由；不访问真实设备。验证记录见 [背景组合证据](../../docs/evidence/2026-10-24-background-composition.md)。

## 独立开发页面（保留）

本机已准备资源：

```sh
cb avatar
```

在 Chrome 打开 `http://127.0.0.1:5778`，点“动作演示”或“测试图驱动”。当前为居中的半身像，旧全身视角已退出；已有页面请刷新以加载新驱动。摄像头默认关闭，只有主动点击“开启摄像头”才申请权限；停止、隐藏或关闭页面都会停止采集。退出服务用 Ctrl+C；先在页面点“停止”可立即释放相机。此命令保留独立开发页面；应用内入口无需手动运行它。

体验人物替换：开启摄像头即可持续分割并合成现场与虚拟角色，无需离场采集。被真人遮挡的区域采用周围背景颜色近似补洞，可能出现涂抹或延展，不是实景重建。现场与遮罩同帧；可靠结果过期或缺失时停用现场层。选择静态背景时才离场至少五秒并人工确认。光照、多人与复杂遮挡仍需验收，不能视为保证不漏人的隐私滤镜。

其他机器首次准备（Node.js 22+、npm、curl；会联网下载锁定依赖和固定测试资源）：

```sh
sh rust/scripts/avatar-lab.sh prepare
cb avatar
```

资源在 `rust/build/avatar-assets/`，文件与 SHA256 在 `assets.lock.json`。已有资源校验正确即复用，损坏则报错，不覆盖或默默重下。需要代理时显式设置 `CB_AVATAR_PROXY` 给资源准备脚本；npm 的代理使用其自身配置。运行不访问 CDN，不下载浏览器。

```sh
# 修改源码后重建，不下载资源
sh rust/scripts/avatar-lab.sh build
# 数值单测 + 隔离浏览器真实模型/渲染检查，不开启真实摄像头
sh rust/scripts/avatar-lab.sh test
# 仅在已明确授权摄像头时运行，真实采集约 30 秒后停止；不录制
node rust/avatar/scripts/check-camera.mjs --confirm-camera
```

默认使用本机 `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`，其他位置通过 `CB_AVATAR_BROWSER` 指定。摄像头检查需图形登录会话和系统摄像头权限；不绕过 macOS 授权。`CB_AVATAR_PORT` 可调整服务端口。

- `src/rig.mjs`：数值解算适配、输入副本、停止代次与单帧在途控制。
- `src/motion.mjs`：VRM 版本坐标转换、父子旋转、眨眼稳定、按骨过期、固定半身中心、掌面和逐指节方向、无人待机。
- `src/rotation-filter.mjs`：1€ 思路的旋转自适应低通与单帧翻转确认，不新增模型。
- `src/signals.mjs`：宽高比修正、五种口型、掌面基准、面部/肩肘/全身入画状态与失踪期限。
- `src/appearance.mjs`：原 VRM 上衣配色、立体衣领、门襟、纽扣与发饰，新增 14 网格 / 600 顶点。
- `src/live-background.mjs`：有界多源传播补洞，不增加模型；只从同帧已判为背景的像素取色。
- `src/replacement.mjs`：空背景倒计时/人工确认、人物遮罩扩张、同帧背景补全、角色合成和过期回退。
- `src/app.mjs`：角色加载、骨骼/表情绑定、本地预览和明确启动的采集。
- `scripts/build.mjs`：资源摘要、按需复制和体积报告，不改模型权重。
- `scripts/check-browser.mjs`：真实公开图片推理/分割、最终合成像素、模拟视频完整采集确认流程、停止/迟到授权、窄屏及外联检查；设备接口替身不会访问真实相机。

产物在 `rust/build/avatar/`；体积见 `rust/build/avatar-size.json`，截图及数值报告见 `rust/build/avatar-check/`。开发页仍保留测试图与诊断接口；它们不构成任意第三方插件接口或设备输出授权。

只驱动头脸、肩臂和双手，固定髋部与双腿。顶部提示分别说明面部是否完整、肩肘是否入画和手部数量；手没入画仍可跟踪面部。无人超过约 700 ms 自动待机，闭嘴并自然呼吸/眨眼；相机仍在检测，点击“停止”才释放设备。

角色“澄 · 通话装”在官方 VRM 基底上完善服装与发饰，原脸型、骨架、纹理和表情资源保留，不是从零建模的新角色。原文件摘要不变，外观修改在本地运行时生效。口型、手指遮挡和自然度仍需真人验收。

当前已接入本地现场背景合成和自有虚拟摄像头代码；自有设备仍待签名安装，另有下述 OBS 本地验证入口。没有 TTS 口型；WKWebView 加载、公开图推理与内存帧检查已通过；真人替换边缘、不同光照、Safari 独立兼容、长期性能和新窗口实际通话仍需验收。所用模型、纹理和跟踪输入未量化/降采样；背景合成副本限 640×480。来源见 [THIRD_PARTY.txt](THIRD_PARTY.txt)，当前路线见 [VirtualAvatar.md](../../VirtualAvatar.md)。

## 自有摄像头帧桥

`cb camera-build` 构建独立宿主/扩展/发送器，`cb camera-check` 只读查询设备，`cb camera-setup` 打开安装面板。默认检查构建使用 ad-hoc 签名、禁用安装；当前用户无开发者账号，不能接通真实虚拟设备。具备团队签名并完成安装后，页面才可主动开启视频输出，安装本身不发送。

`src/video-output.mjs` 只接收最终画布；`scripts/camera-bridge.mjs` 以匿名管道启动固定发送器，`server.mjs` 检查同源、令牌和会话。每次最多一个在途帧，停止/页面隐藏使会话失效；音频模块不参与。App 已使用系统 WebView，Node 服务由宿主私有管道管理；保留浏览器开发入口，不捆绑 Chromium。

```sh
# 先构建摄像头及页面；只用合成图，不启动任何音视频设备
python3 rust/scripts/check-camera-bridge.py
node rust/avatar/scripts/check-video-output.mjs
```

第二项由测试代码注入 `memoryOnly`，HTTP 参数不能选择它；界面明确显示“内存帧检查中”，原生生成 CMSampleBuffer 后释放，不入设备队列。结果在 `rust/build/camera/`。正常服务不会偷偷以测试模式代替真实输出。签名与验收边界见[摄像头记录](../../docs/evidence/2026-10-22-camera-bridge.md)。

## OBS 本地通话测试

本机已安装并批准官方 OBS 32.2.2 摄像头扩展。没有 Apple 开发者账号时，可以用它验证最终画面输出；自有摄像头方案保留，普通 `cb avatar` 不自动切换 OBS。

1. 退出 OBS 主程序（扩展继续由系统提供）。
2. 执行 `cb avatar-obs`，在 Chrome 打开 `http://127.0.0.1:5778`。
3. 点击“动作演示”，再点“开始视频输出”。此演示不打开物理摄像头或麦克风。
4. 在支持设备选择的通话软件中选择 **OBS Virtual Camera**。不要同时从 OBS 主程序启动虚拟输出。
5. 结束时点击“停止视频输出”。隐藏/关闭网页也会停止，因此使用时保持页面可见；通话端也可直接关闭摄像头。

原生发送器读取签名 OBS bundle 的设备 UUID，直接交付最终画布，不依赖 OBS 窗口捕获，不采集桌面。OBS 独立安装，未捆绑进 CallBridge。

经授权运行 `node rust/avatar/scripts/check-obs-camera.mjs --confirm-virtual-video` 可复核真实虚拟设备 → 本机 WebRTC → 接收画面与停止。它只精确打开 OBS 设备，`audio:false`，无外部 ICE 服务器或联系人通话。报告和合成角色截图位于 `rust/build/camera/obs-device-report.json`、`obs-webrtc-received.png`、`obs-webrtc-stopped.png`。

本次角色运动和停止占位检查通过；无界面 Chrome 的接收统计约 1–2 fps，WebRTC 自适应降至 480×270，不代表 720p30 流畅度通过。用户随后已确认网页/OBS 链路可用，但没有具体客户端版本或量化远端记录；应用内真人通话仍需单独确认。OBS 的停止行为也不等同于自有扩展的 500 ms 失联保护。

## 目录预览维护

`preview.jpg` 为当前角色真实最终画布的静态截图，16,642 字节，随主 App 发布；不改变插件清单、模型精度或纹理。它是外观预览，不代表真人跟踪效果验收。需要更新时，显式运行 `node rust/avatar/scripts/export-preview.mjs`，使用本地构建资源与隔离浏览器，不采集或发送媒体；普通构建只复制此图片。

分类/插件列表不加载 WebView 或服务。返回详情停止当前运行，离开详情取消安装；重开窗口回到分类，不恢复输出。当前目录为固定审核入口，尚非通用第三方导入器。

`node rust/avatar/scripts/check-live-avatar.mjs` 使用公开图片与连续变色合成视频验证无需采集空背景的实时角色组合；不访问真实设备，截图为 `rust/build/live-avatar-preview.png`。
