/*
本文件的目的：用 AppKit 绘图生成可复现的技术图草稿，输出到 rust/build/diagram-drafts。
为什么不写回 assets/diagrams？文档现在使用单独生成的插画，运行此脚本不能覆盖它们。
为什么把绘图操作包装成 Diagram？字体、颜色、卡片和连线集中管理，避免每张草稿各画一套。
这是离线文档辅助脚本，不参与 App 构建，不访问声音设备。
*/
import AppKit
import Foundation

// #filePath 是当前源文件位置；向上两级得到项目目录，避免依赖终端当前路径。
let outputDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("rust/build/diagram-drafts")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// 0xRRGGBB 拆成红、绿、蓝三个字节，再除以 255 映射到颜色接口要求的 0～1。
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

let ink = color(0x182D41)
let muted = color(0x52667A)
let teal = color(0x087F83)
let blue = color(0x355FC1)
let amber = color(0xAE681C)
let violet = color(0x7253A3)
let red = color(0xAF4B50)
let paper = color(0xF4F7FA)
let rule = color(0xD7E1E9)

// 一张图拥有一块位图和绘图上下文；尺寸与布局坐标统一使用像素尺度。
final class Diagram {
    let width: CGFloat = 1800
    let height: CGFloat
    let bitmap: NSBitmapImageRep
    let context: NSGraphicsContext

    init(height: Int) {
        // 每像素 RGBA 四个 8 位分量；直接画到内存，不必先打开 GUI 窗口截图。
        self.height = CGFloat(height)
        bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        // 把原点换到左上角、y 轴向下，排版时“从上到下”就对应递增的 y。
        graphics.translateBy(x: 0, y: CGFloat(height))
        graphics.scaleBy(x: 1, y: -1)
        context = NSGraphicsContext(cgContext: graphics, flipped: true)
        // 保存外部上下文，save() 时恢复，避免一张图的坐标变换污染下一张图。
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        paper.setFill()
        NSRect(x: 0, y: 0, width: width, height: self.height).fill()
    }

    // 1. 先测量文字占用范围，再画字；越界就明确失败，不生成被截断但看似成功的图片。
    func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat,
              size: CGFloat = 25, weight: NSFont.Weight = .regular,
              tint: NSColor = ink, height: CGFloat = 300) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: tint, .paragraphStyle: style
        ]
        let string = NSAttributedString(string: value, attributes: attributes)
        let measured = string.boundingRect(with: NSSize(width: width, height: 10000),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
        precondition(measured.height <= height + 2, "Text overflow: \(value)")
        precondition(x >= 0 && y >= 0 && x + width <= self.width && y + measured.height <= self.height,
                     "Text outside canvas: \(value)")
        string.draw(with: NSRect(x: x, y: y, width: width, height: height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    // 2. 统一圆角矩形样式：先填背景，再描边，避免重复写基础绘图步骤。
    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
              fill: NSColor = .white, stroke: NSColor = rule, radius: CGFloat = 20) {
        let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                                xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    // 3. 用折线连接节点；箭头方向取最后两点，不假设所有连线都从左向右。
    func line(_ points: [(CGFloat, CGFloat)], tint: NSColor = teal,
              dashed: Bool = false, arrow: Bool = true) {
        precondition(points.count > 1)
        let path = NSBezierPath()
        path.lineWidth = 3
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: points[0].0, y: points[0].1))
        for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
        if dashed { path.setLineDash([9, 8], count: 2, phase: 0) }
        tint.setStroke()
        path.stroke()
        if arrow {
            let end = points[points.count - 1]
            let before = points[points.count - 2]
            // atan2 求末段方向，再向两侧偏转一点，得到箭头三角形的两个侧点。
            let angle = atan2(end.1 - before.1, end.0 - before.0)
            let head = NSBezierPath()
            head.move(to: NSPoint(x: end.0, y: end.1))
            head.line(to: NSPoint(x: end.0 - 15 * cos(angle - 0.42), y: end.1 - 15 * sin(angle - 0.42)))
            head.line(to: NSPoint(x: end.0 - 15 * cos(angle + 0.42), y: end.1 - 15 * sin(angle + 0.42)))
            head.close()
            tint.setFill()
            head.fill()
        }
    }

    // 4. 标题、分节、卡片和横幅是排版组件，下面三张图只负责提供内容和位置。
    func header(_ number: String, _ title: String, _ subtitle: String) {
        text("CALLBRIDGE  /  \(number)", 70, 45, 1660, size: 23, weight: .bold, tint: teal, height: 40)
        text(title, 70, 98, 1660, size: 53, weight: .bold, height: 80)
        text(subtitle, 70, 181, 1660, size: 26, tint: muted, height: 60)
        line([(70, 255), (1730, 255)], tint: rule, arrow: false)
    }

    func section(_ label: String, _ y: CGFloat, detail: String = "", tint: NSColor = teal) {
        text(label, 80, y, 1640, size: 31, weight: .bold, tint: tint, height: 50)
        if !detail.isEmpty { text(detail, 80, y + 49, 1640, size: 23, tint: muted, height: 65) }
    }

    func card(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
              _ label: String, _ title: String, _ body: String, tint: NSColor = teal) {
        rect(x, y, width, height)
        rect(x + 22, y + 23, 5, 29, fill: tint, stroke: tint, radius: 2)
        text(label, x + 40, y + 22, width - 62, size: 21, weight: .semibold, tint: tint, height: 36)
        text(title, x + 24, y + 64, width - 48, size: 29, weight: .bold, height: 48)
        text(body, x + 24, y + 114, width - 48, size: 23, tint: muted, height: height - 132)
    }

    func band(_ y: CGFloat, _ title: String, _ body: String, tint: NSColor = teal, height: CGFloat = 132) {
        rect(80, y, 1640, height, fill: tint.withAlphaComponent(0.055), stroke: tint.withAlphaComponent(0.3))
        text(title, 106, y + 20, 1588, size: 28, weight: .bold, tint: tint, height: 43)
        text(body, 106, y + 68, 1588, size: 24, tint: ink, height: height - 80)
    }

    func save(_ name: String) throws {
        // 从位图编码为 PNG；throws 把写入失败交给调用者，而不是吞掉错误。
        NSGraphicsContext.restoreGraphicsState()
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: outputDirectory.appendingPathComponent(name))
        print("\(name): 1800 × \(Int(height))")
    }
}

// 5. 经典声音生命周期草稿；三列蛇形阅读，编号明确每一步的实际顺序。
func lifecycle() throws {
    let drawing = Diagram(height: 2420)
    drawing.header("01 · AUDIO LIFECYCLE", "一段声音，怎样穿过软硬件", "经典实时通话链路 · 从空气振动到数字样本，再回到对方耳中的声音")
    let columns: [CGFloat] = [80, 640, 1200]
    let rows: [CGFloat] = [360, 730, 1100, 1470, 1840]
    let titles = ["A / 本地硬件：声音被采样", "B / 本地软件：操作系统交付 PCM", "C / 通话与网络：样本变成数据包", "D / 对端软件：按播放时间恢复 PCM", "E / 对端硬件：数字重新变成声音"]
    for index in 0..<rows.count { drawing.section(titles[index], rows[index] - 70, tint: index == 0 || index == 4 ? amber : teal) }
    let blocks: [(String, String, String, NSColor)] = [
        ("01 · 空气", "人声 / 声压变化", "声带使空气振动\n此时没有数字音频文件\n也没有 PCM 样本", amber),
        ("02 · 换能与模拟前端", "麦克风 → 电信号", "振膜把声压变成电信号\n前置放大与抗混叠滤波\n增益影响采集电平", amber),
        ("03 · 音频硬件", "ADC → 数字样本", "按采样时钟量化电信号\n样本位深决定量化精度\n数据按通道组成音频帧", amber),
        ("06 · 应用内存", "PCM 缓冲与处理", "一块缓冲容纳一段样本\n按需重采样、映射声道\n降噪 / 增益由应用决定", blue),
        ("05 · 系统接口", "输入 I/O → 应用", "Core Audio 输入接口\n按周期交付样本和时间戳\nAUHAL 是一种接入方式", blue),
        ("04 · 驱动与硬件抽象", "设备驱动 → HAL", "驱动对接物理音频设备\nHAL 统一设备、流和属性\n提供格式与时序信息", blue),
        ("07 · 通话应用", "编码与分帧", "PCM → 压缩音频帧\n编解码器由通话软件选择\n不是直接发送整段 WAV", teal),
        ("08 · 发送端网络栈", "封装与传输", "打包、时间信息与安全传输\n使用客户端自身的协议\n网络延迟与丢包影响声音", teal),
        ("09 · 对端接收", "网络包到达", "包可能迟到、乱序或丢失\n先交给通话软件处理\n不能直接推给扬声器", teal),
        ("12 · 输出侧系统接口", "播放缓冲 → HAL", "应用提供播放所需 PCM\n输出回调按设备节拍取帧\n格式与声道按输出端适配", blue),
        ("11 · 通话解码器", "压缩帧 → PCM", "解码为连续数字音频样本\n按策略处理丢包 / 欠载\n为输出设备准备音频块", blue),
        ("10 · 接收缓冲", "抖动缓冲与排序", "按时间线整理收到的包\n短暂等待以平衡延迟和连续性\n不是无限等待所有数据", blue),
        ("13 · 输出硬件", "驱动 → DAC", "设备驱动交付数字样本\nDAC 按本地时钟转换\n恢复连续模拟电信号", amber),
        ("14 · 电声转换", "放大器 → 耳机", "模拟电信号驱动振膜\n振膜再次推动空气\n音量由播放链路共同决定", amber),
        ("15 · 终点", "对方真正听到", "声波进入耳朵\n清晰度、首尾和延迟体感\n最终要由接听者确认", amber)
    ]
    // index % 3 选列，index / 3 选行；卡片文案与统一绘图函数分离。
    for index in 0..<blocks.count {
        let block = blocks[index]
        drawing.card(columns[index % 3], rows[index / 3], 520, 250,
                     block.0, block.1, block.2, tint: block.3)
    }
    for row in 0..<5 {
        let center = rows[row] + 125
        if row % 2 == 0 {
            drawing.line([(600, center), (640, center)])
            drawing.line([(1160, center), (1200, center)])
        } else {
            drawing.line([(1200, center), (1160, center)])
            drawing.line([(640, center), (600, center)])
        }
        if row < 4 {
            let edge: CGFloat = row % 2 == 0 ? 1750 : 50
            let column = row % 2 == 0 ? 2 : 0
            let endpoint = row % 2 == 0 ? columns[column] + 520 : columns[column]
            drawing.line([(endpoint, center), (edge, center), (edge, rows[row + 1] + 125),
                          (endpoint, rows[row + 1] + 125)])
        }
    }
    drawing.band(2150, "贯穿全程的三件事：格式、缓冲、时钟", "PCM 是样本，不是声波；缓冲是临时存放，不等于录音文件；不同设备 / 网络之间需要时间与速率适配。", height: 132)
    drawing.text("48 kHz = 每声道每秒 48,000 个样本 · 512 帧约 10.67 ms · 帧数不等于字节数", 90, 2310, 1620, size: 23, tint: muted, height: 40)
    drawing.text("参考：Apple Core Audio Overview · 通用链路示意，不指定 FaceTime / 微信的私有编解码与传输实现", 90, 2360, 1620, size: 21, tint: muted, height: 40)
    try drawing.save("01-audio-lifecycle.png")
}

// 6. 总体技术方案草稿：控制面、音频面、视频面、资源扩展与停止语义分区排布。
func architecture() throws {
    let drawing = Diagram(height: 4920)
    drawing.header("02 · SYSTEM DESIGN", "CallBridge 总体技术方案", "Rust 核心 × 原生系统适配 × 虚拟音视频设备  /  方案署名：GPT6 Astra")
    drawing.band(290, "产品边界：处理自己的输出，不改造通话软件", "文字 / 授权音源 / 角色素材 → 本地处理 → 虚拟设备 → 通话软件 → 网络 → 对方；声音与画面分开输送。", height: 132)

    drawing.section("01 / 控制面：一次操作，统一管理音频与视频", 465)
    drawing.card(80, 535, 520, 280, "AppKit · 主线程", "输入与明确授权", "文字 / 声音 / 模式 / 角色选择\n发送、取消本句、停止全部\n现场麦克风与摄像头分别授权\n只展示必要控制与路由状态", tint: blue)
    drawing.card(640, 535, 520, 280, "Rust · session", "状态与取消代次", "命令 → 意图校验 → 状态转移\n每次任务分配 generation\n迟到回调必须匹配当前代次\n模式 / 设备切换清空旧任务")
    drawing.card(1200, 535, 520, 280, "原生适配 · 控制线程", "设备与生命周期", "枚举 UID、格式、权限与存活\n显式绑定输入 / 输出设备\n停止、睡眠、失败统一收敛\n状态快照返回 UI，不阻塞回调", tint: blue)
    drawing.line([(600, 675), (640, 675)])
    drawing.line([(1160, 675), (1200, 675)])

    drawing.section("02 / 音频面：三种来源，统一成可发送的 PCM", 865,
                    detail: "A0 = 仅文字语音；A1 = 文字语音 + 现场环境；A2 = 文字语音 + 自定义背景。三种模式互斥。")
    drawing.card(80, 985, 520, 320, "A0 / A1 / A2 · TTS", "文字 → 系统合成", "文本校验：非空、最多 280 标量\nAVSpeechSynthesizer 回调取 PCM\n单句最多 30 秒，等待上限 25 秒\n检查有限值、电平与格式一致性\nAVAudioConverter → 48 kHz mono\n转换器 drain 后才交付完整结果")
    drawing.card(640, 985, 520, 320, "仅 A1 · 真实输入", "麦克风 → 环境 PCM", "主动开启并授予麦克风权限\n独立输入实例，不复用输出 AUHAL\n采集 PCM、设备时钟与时间戳\n缓冲水位 + 自适应重采样校漂移\n送入有界环境音队列\n会包含真实人声，不承诺只留背景", tint: amber)
    drawing.card(1200, 985, 520, 320, "仅 A2 · 文件输入", "素材 → 背景 PCM", "导入授权的本地 WAV / PCM 素材\n非实时线程解析、解码与限长\n统一采样率、声道和数值格式\n循环边界交叉淡化，避免突变\n录制素材须独立授权 / 保存确认\n播放素材不等于继续开启麦克风", tint: violet)
    for center in [340.0, 900.0, 1460.0] {
        drawing.line([(center, 1305), (center, 1345)], arrow: false)
    }
    drawing.line([(340, 1345), (1460, 1345)], arrow: false)
    drawing.line([(480, 1345), (480, 1390)])
    drawing.card(80, 1390, 800, 290, "Rust · 非实时准备", "有界缓冲与所有权", "PCM 统一为 Float32 / 48 kHz；任务带 generation\n单句播放器持有独立副本，不借用短命合成缓冲\n流式音源经有界 SPSC 送入实时侧，不无限积压\n输入指针、容量、帧数和声道各自校验\n内存分配、解码和资源释放留在非实时线程")
    drawing.card(920, 1390, 800, 290, "Rust · audio engine / 实时消费", "混音、压低背景与限幅", "只读当前代次：TTS + 当前模式允许的背景\n音源独立增益；TTS 实际播放时平滑压低背景\n语音结束后恢复背景；总输出限幅防止削波\n缺数据补零；过载按策略丢弃并计数\n输出样本位置驱动播放进度与角色嘴部")
    drawing.line([(880, 1535), (920, 1535)])
    drawing.line([(1320, 1680), (1320, 1725), (340, 1725), (340, 1780)])
    drawing.card(80, 1780, 520, 310, "C · 输出专用 AUHAL", "绑定虚拟输出", "绑定 BlackHole16ch_UID\n校验 virtual / alive / 48 kHz / 16ch\nEnableIO：输入 bus 1 = 0\n输出 bus 0 = 1；初始化后复核\nrender 按需取帧，不锁 / 不分配\nmono → 通道 1/2；3–16 补零", tint: blue)
    drawing.card(640, 1780, 520, 310, "系统进程 · 虚拟音频设备", "BlackHole 回环", "应用写入设备输出侧\n驱动按音频时间线提供输入侧\n不经过本机扬声器 / ADC\n通话软件像选麦克风一样选择它\n外部驱动不处理文字或角色资源\n不是某一次通话专属的私密通道", tint: blue)
    drawing.card(1200, 1780, 520, 310, "通话软件 · 自身进程", "读取 → 编码 → 传输", "FaceTime / 微信选择虚拟输入\n继续遵守客户端自己的静音控制\n客户端决定降噪、编码与网络协议\n远端解码 → 输出设备 → 耳机\nCallBridge 不注入客户端进程\n本地发送结束不等于远端已播放", tint: blue)
    drawing.line([(600, 1935), (640, 1935)])
    drawing.line([(1160, 1935), (1200, 1935)])
    drawing.band(2130, "实时与控制线程隔离", "实时回调只消费准备好的数据；TTS、解码、模型推理、文件 IO、内存回收与 GPU 等待不进入音频回调。", height: 132)

    drawing.section("03 / 视频面：驱动角色或模板，只交付最终画面", 2310,
                    detail: "音频与视频共用会话意图；摄像头不是使用 cartoon 的前提。视频扩展不接触文字历史、物理麦克风或角色代码。", tint: violet)
    drawing.card(80, 2430, 520, 300, "输入 · AVFoundation / 音频时序", "动作与口型来源", "授权摄像头 → 采集帧与时间戳\n无摄像头 → 待机动作 + TTS 嘴部\n嘴部读取实际消费 PCM 的包络\n不拿整句预合成音量提前张嘴\n嘴部开合不冒充音素级口型", tint: violet)
    drawing.card(640, 2430, 520, 300, "Vision + Rust · video core", "姿态 → 统一 RigState", "Vision 提取脸部 / 身体关键点\nRust 归一化、平滑与动作映射\n角色：头部、眨眼、躯干、嘴部\n服装：肩颈锚点、缩放与有限变形\n跟踪丢失 → 中性角色 / 隐私帧", tint: violet)
    drawing.card(1200, 2430, 520, 300, "Metal · 渲染适配", "合成最终画面", "cartoon = 角色 + 合成背景\ncartoon 不混入摄像头原始像素\n服装模式 = 真人帧 + 模板覆盖\n限定单人正面场景与遮挡范围\n无法安全覆盖时输出隐私画面", tint: violet)
    drawing.line([(600, 2580), (640, 2580)], tint: violet)
    drawing.line([(1160, 2580), (1200, 2580)], tint: violet)
    drawing.line([(1460, 2730), (1460, 2800)], tint: violet)
    drawing.card(1200, 2800, 520, 300, "帧交换 · 进程边界", "IOSurface 有界槽位", "生产者写最终帧，不发原始相机帧\nIPC 传槽位、序号、generation、PTS\n明确 retain / release 与读写所有权\n只保留新帧，不无限排队追赶\n首个输出规格：720p / 30 fps", tint: violet)
    drawing.card(640, 2800, 520, 300, "Swift · CMIO Camera Extension", "发布虚拟摄像头", "接收最终画面与合法时间戳\n向系统发布摄像头设备 / 视频流\n断连、超时、旧代次 → 隐私画面\n只做帧发布，不加载第三方插件\n签名、权限与扩展激活独立管理", tint: violet)
    drawing.card(80, 2800, 520, 300, "通话软件 · 设备选择", "摄像头 → 网络 → 对方", "用户选择 CallBridge 虚拟摄像头\n客户端分别消费音频与视频设备\n编码与网络同步由客户端参与\n输入静音 / 关摄像头仍然有效\n不绕过客户端权限与通话控制", tint: violet)
    drawing.line([(1200, 2950), (1160, 2950)], tint: violet)
    drawing.line([(640, 2950), (600, 2950)], tint: violet)
    drawing.band(3140, "音画同步：以实际输出为准，不以生成完成为准", "音频样本位置映射 host clock，视频 PTS 使用同一时间域；有界补偿延迟，睡眠后重建映射，不承诺远端零偏差。", tint: violet, height: 132)

    drawing.section("04 / 资源扩展：换素材，不改音视频传输链路", 3320, tint: violet)
    drawing.card(80, 3390, 520, 270, "合作者", "制作声明式资源包", "manifest、版本与角色 ID\n图片 / 网格 / 锚点 / 动作映射\n标明素材授权与依赖\n不携带任意 dylib 或可执行脚本", tint: violet)
    drawing.card(640, 3390, 520, 270, "导入流程", "校验与安全装载", "检查路径、大小、格式和版本\n限制纹理尺寸与资源总量\n拒绝越界引用和不兼容的绑定\n加载失败不替换当前可用资源", tint: violet)
    drawing.card(1200, 3390, 520, 270, "统一 renderer", "选择模板 → 驱动角色", "把动作绑定到统一 RigState\n沿用同一渲染与虚拟摄像头链路\n角色切换使用新的 generation\n新渲染器属于代码审查与发行", tint: violet)
    drawing.line([(600, 3525), (640, 3525)], tint: violet)
    drawing.line([(1160, 3525), (1200, 3525)], tint: violet)

    drawing.section("05 / 停止与故障：先截断旧任务，再安全释放", 3710, tint: red)
    drawing.card(80, 3780, 520, 310, "触发条件", "取消 / 切换 / 失联", "取消本句只撤销当前 TTS\n音频静音阻断全部音频源\n停止全部关闭现场采集与发送\n设备异常、睡眠触发安全收敛\n视频切换中保持隐私输出\n真实采集恢复需要明确用户意图", tint: red)
    drawing.card(640, 3780, 520, 310, "Rust + 原生控制层", "代次失效 → 停止 IO", "generation 更新，迟到结果丢弃\n取消合成与播放器，音频补零\n视频使用中性角色 / 隐私帧\n停止、反初始化、销毁 AudioUnit\n确保回调不再访问后释放 Rust PCM\n清理失败禁止继续发送，保留引用", tint: red)
    drawing.card(1200, 3780, 520, 310, "用户可见语义", "不隐式回退", "不自动打开真实麦克风 / 摄像头\n不把原始真人画面作为失败兜底\n不更改系统默认输入 / 输出\n无法撤回已经进入通话链的声音\n客户端自身回退行为需单独约束\n不将程序内取消当成远端即时静音", tint: red)
    drawing.line([(600, 3935), (640, 3935)], tint: red)
    drawing.line([(1160, 3935), (1200, 3935)], tint: red)

    drawing.section("06 / 底层演进：设备接口稳定，驱动实现可替换", 4140)
    drawing.card(80, 4210, 800, 290, "虚拟音频后端", "BlackHole / 自研 HAL 设备", "上层保留 Rust PCM 与输出适配边界，后端不承担 TTS\n自研路线：C 使用 Apple SDK ABI → Rust HAL 核心\n设备属性、时钟、sample-time 回环与多读者隔离\nApp 内单消费者队列不能直接充当驱动多读者时间线\n签名、公证、安装和卸载作为系统组件流程处理", tint: blue)
    drawing.card(920, 4210, 800, 290, "声音来源边界", "Tap 不是混音器，也不是虚拟麦克风", "TTS 来自系统合成；现场环境来自授权麦克风输入\n背景素材来自文件解码；这三条链路不依赖 Process Tap\n如需采集其他应用播放声，再单独设计 Tap 与授权\n不同来源最后由 Rust 混音，再交给虚拟设备\n不能将采集、混音、设备发布混为同一层", tint: blue)
    drawing.band(4550, "完整数据生命周期", "创建任务 → 授权与校验 → 生成 / 采集 → 格式统一 → 有界缓冲 → 实时消费 → 虚拟设备 → 通话 → 停止与释放。", height: 132)
    drawing.text("数据面：PCM / 视频帧  ·  控制面：命令 / generation / 权限 / 生命周期  ·  时间面：sample position / host clock / PTS", 90, 4720, 1620, size: 24, tint: muted, height: 76)
    drawing.text("设计依据：Apple Core Audio / AVFAudio / Vision / CoreMediaIO · BlackHole · CallBridge 音视频架构与资源包契约", 90, 4820, 1620, size: 22, tint: muted, height: 55)
    try drawing.save("02-callbridge-architecture.png")
}

// 7. 类比草稿：用纸条、配音员、托盘和传送带对应文字、TTS、缓冲与虚拟设备。
func analogy() throws {
    let drawing = Diagram(height: 2300)
    drawing.header("03 · THE SIMPLE VERSION", "把它想成一间电话配音工作室", "你递纸条，配音员开口；电话照常打，声音不必来自你的嘴。")
    let blocks: [(CGFloat, CGFloat, String, String, String, NSColor)] = [
        (80, 350, "01 · 你", "写一张纸条", "输入“你好，等我一下。”\n按发送才交出去\n没有按发送，工作室就不念\n对应：输入框与发送按钮", blue),
        (640, 350, "02 · 配音员", "替你把纸条念出来", "把文字变成一段配音\n可以选中文或英文声音\n不是把你的说话声放大\n对应：系统文字转语音", teal),
        (1200, 350, "03 · 托盘与管理员", "暂存，再按顺序交付", "配音被切成一小份一小份\n托盘有容量，不能无限堆积\n管理员只交付当前任务\n对应：缓冲区与 Rust 播放器", teal),
        (1200, 770, "04 · 专用传送带", "送到“麦克风入口”", "声音不从本机扬声器绕一圈\n直接送到软件能选的音频入口\nBlackHole 不负责念纸条\n对应：虚拟音频设备", blue),
        (640, 770, "05 · 电话接线员", "照常把声音传出去", "把输入设备选成 BlackHole\n通话软件拿到的是声音\n它负责打包、联网和发送\n对应：FaceTime / 微信", blue),
        (80, 770, "06 · 对方", "从耳机里听到配音", "对方不用看你的纸条\n也不用安装同一个配音工具\n仍然是在原来的电话里听\n对应：对端解码与播放", amber)
    ]
    for block in blocks {
        drawing.card(block.0, block.1, 520, 310, block.2, block.3, block.4, tint: block.5)
    }
    drawing.line([(600, 505), (640, 505)])
    drawing.line([(1160, 505), (1200, 505)])
    drawing.line([(1460, 660), (1460, 770)])
    drawing.line([(1200, 925), (1160, 925)])
    drawing.line([(640, 925), (600, 925)])
    drawing.band(1130, "为什么不需要你开口？", "纸条直接交给配音员；“真实麦克风”这扇门可以一直关着。虚拟麦克风只是接声音的入口，不是替你说话的人。", height: 132)

    drawing.section("加背景、换形象，也沿用这间工作室", 1320)
    drawing.card(80, 1390, 520, 310, "声音 · 调音台", "给配音铺一层背景", "环境音 = 打开窗，收进现场声音\n自定义音 = 播放你选的背景素材\n配音开始时，调音员调低背景\n最后混成一条声音交给电话\n开窗也会收进你的真实讲话", tint: amber)
    drawing.card(640, 1390, 520, 310, "画面 · 木偶舞台", "让角色替你出镜", "角色像一只按动作表表演的木偶\n配音真的播出时，嘴巴才开合\n可以只待机，不开真实摄像头\n想换角色，就换一套合规素材\n对应：角色包、动作映射与渲染", tint: violet)
    drawing.card(1200, 1390, 520, 310, "视频 · 第二条传送带", "把舞台画面送进电话", "虚拟摄像头像舞台的播出窗口\n只把处理后的画面交给通话软件\n声音走音频线，画面走视频线\n两条线按同一只表安排时间\n衣服模板像按身体位置摆的道具", tint: violet)
    drawing.line([(1160, 1545), (1200, 1545)], tint: violet)

    drawing.section("停止按钮，不是时光倒流按钮", 1750, tint: red)
    drawing.card(80, 1820, 800, 290, "取消 · 作废旧单号", "旧纸条不能偷偷复活", "每次发送都有新单号；停止后，旧单号作废\n即使配音员稍后才交作业，管理员也拒收\n托盘不再继续交付旧任务，重新发送要用新单\n对应：generation、取消合成、停止播放器", tint: red)
    drawing.card(920, 1820, 800, 290, "边界 · 已经送出的声音", "已经进电话的，拿不回来", "停止可以关住工作室出口，但不能收回对方已听到的声音\n传送带旁的其他监听程序，也可能接收到同一份声音\n所以先确认路由，再允许发送；它不是一条私人专线\n故障时宁可静音 / 隐私画面，也不擅自打开真人输入", tint: red)
    drawing.text("一句话：CallBridge 是你的配音与形象工作室，虚拟设备是出口，通话软件是送达对方的电话。", 90, 2180, 1620, size: 29, weight: .semibold, tint: teal, height: 90)
    try drawing.save("03-callbridge-analogy.png")
}

// 顶层 try 顺序生成三张图；任一生成失败就报告错误，不把缺图当作全部完成。
try lifecycle()
try architecture()
try analogy()
