import SwiftUI
import UIKit

// MARK: - 动态颜色（light / dark 自适应）

public extension Color {
    init(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) {
        self.init(uiColor: UIColor(dynamicProvider: { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(Color(hex: dark, alpha: darkAlpha))
                : UIColor(Color(hex: light, alpha: lightAlpha))
        }))
    }
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// 纸底：暖骨色画布——纸感来自温度，冷灰读作「屏幕」、暖骨读作「纸」。
    /// 纸面浮于画布之上靠两者色差 + hairline + 极淡投影分层；暗色黑曜石底不变。
    static let recapBg = Color(light: 0xF6F5F1, dark: 0x0C0E11)
    static let recapPaper = Color(light: 0xFFFFFF, dark: 0x16191D)
    static let recapCurrentBg = Color(light: 0xFFFFFF, dark: 0x1C2025)

    /// 暖墨/暖茶灰：墨与灰都带一点纸的黄向，避免冷屏幕感；暗色侧不变。
    static let recapInk = Color(light: 0x1D1B17, dark: 0xF0F2EE)
    static let recapTea = Color(light: 0x6F6B62, dark: 0x9CA29A)

    /// 投影专用色。通透自然的软阴影，避免脏发灰。
    static let recapShadow = Color(light: 0x000000, lightAlpha: 0.04, dark: 0x000000, darkAlpha: 0.28)

    // 原青瓷品牌色已退役并迁移至 recapInk（91 处引用已机械 rename）。朱砂/赭石仅作功能语义保留。
    static let recapCinnabar = Color(light: 0xC8463C, dark: 0xE15A4E)
    static let recapOchre = Color(light: 0xA87842, dark: 0xC99659)

    // MARK: 双层容器（Double-Bezel）专用色
    /// 外壳底：比纸面低一档的「哑光机壳」。light 半透白叠在 recapBg 上、dark 微亮于底。
    static let recapShell = Color(light: 0xFFFFFF, lightAlpha: 0.55, dark: 0xFFFFFF, darkAlpha: 0.05)
    /// 外壳 hairline：茶灰描边，dark 提档保证可见。
    static let recapShellRing = Color(light: 0x6E7671, lightAlpha: 0.10, dark: 0x9CA29A, darkAlpha: 0.14)
    /// 内芯顶部高光：只描上半段的 1px「车削反光」。
    static let recapCoreGlow = Color(light: 0xFFFFFF, lightAlpha: 0.45, dark: 0xFFFFFF, darkAlpha: 0.08)

    /// AI 对话强调色谱（电光青·蓝·翠）——AskBar 边框/发送钮、AgentInvokeSheet 发送钮统一用此，
    /// 与 LIVE 推理绿光晕(GeminiFluidGlowView)的青色端同谱：科技/未来感，但不与既有绿光晕突兀。
    static let recapAICyan = Color(hex: 0x22D3EE)
    static let recapAIBlue = Color(hex: 0x3B82F6)
    static let recapAITeal = Color(hex: 0x2DD4BF)

    /// 说话人灰度阶梯（中性）：主说话人对比最强，逐档递减。
    /// light 深→浅、dark 浅→深，保证两种模式下 speaker0 都是最高对比。
    static func speaker(_ i: Int) -> Color {
        let palette: [(UInt32, UInt32)] = [
            (0x111614, 0xF0F2EE),  // 墨 / 近白（最强）
            (0x454D47, 0xB5BCB4),
            (0x6E7671, 0x9CA29A),  // tea 档
            (0x8C938E, 0x767D75),
            (0xB0B7B1, 0x5D635C),  // 淡（最弱）
        ]
        let (l, d) = palette[abs(i) % palette.count]
        return Color(light: l, dark: d)
    }

    /// 活动热力图色阶：青蓝科技递进（符合附图高质感青蓝点缀点）。i 取 1..4。
    static func heatmapLevel(_ i: Int) -> Color {
        let palette: [(UInt32, UInt32)] = [
            (0xA5F3FC, 0x164E63),  // L1 柔青 (Cyan-200)
            (0x67E8F9, 0x0891B2),  // L2 Cyan-300
            (0x22D3EE, 0x06B6D4),  // L3 Cyan-400
            (0x2DD4BF, 0x0D9488),  // L4 极亮点缀青
        ]
        let idx = max(0, min(i - 1, palette.count - 1))
        let (l, d) = palette[idx]
        return Color(light: l, dark: d)
    }
}

public extension Font {
    // MARK: - 字体系统（13 语义 token）
    // 病根：旧 16 token 仅 13% 采用，368 处 ad-hoc 散落 22 种点数。
    // 新系统按「语义角色」收敛，每档不可替代；tracking/lineSpacing 走 Tracking/Leading 枚举。

    // a11y 合规：Font.system(size:) 本身不随 Dynamic Type 缩放；固定点数经 UIFontMetrics 按当前
    // preferredContentSizeCategory 换算。token 用 computed，视图在 Dynamic Type 变化时重渲染即取最新值。
    // 阶梯/语义角色不变（仅加缩放）；368 处 ad-hoc Font.system 调用未迁移、暂不缩放，后续 typography 重构再迁。
    private static func scaledFont(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: UIFontMetrics.default.scaledValue(for: size), weight: weight, design: design)
    }

    // 展示层
    /// 罕用大展示（保留位）。
    static var recapDisplay: Font { scaledFont(34, weight: .semibold).leading(.tight) }
    /// 英雄字：首页「纪要」、空态标题、设置页英雄。28 semibold，克制现代。
    static var recapHero: Font { scaledFont(28, weight: .semibold).leading(.tight) }

    // 标题层
    /// 文档标题：笔记自身标题，需存在感。22 semibold。
    static var recapTitle: Font { scaledFont(22, weight: .semibold).leading(.tight) }
    /// 卡片/栏标题：会议卡标题、滚动态顶栏、Sheet 标题。17 semibold。
    static var recapTitleS: Font { scaledFont(17, weight: .semibold) }
    /// 内联小标题：议题标题、区段内联标题、行强调。15 semibold。
    static var recapHeading: Font { scaledFont(15, weight: .semibold) }

    // 眉标
    /// 段首眉标（今天/昨天/区段名）：12 semibold，配 Tracking.eyebrow 正字距（小帽字感）。
    static var recapEyebrow: Font { scaledFont(12, weight: .semibold) }

    // 正文层
    /// 阅读正文：转写、纪要摘要、Markdown 正文。16 regular。
    static var recapBody: Font { scaledFont(16) }
    /// 次正文：项目符号、议程、用户气泡、卡片预览。15 regular。
    static var recapBodyS: Font { scaledFont(15) }
    /// 润色行（有别于原话时）：16 semibold（与 recapBody 同尺寸，仅字重升级）。
    static var recapPolished: Font { scaledFont(16, weight: .semibold) }
    /// LIVE/原话行：16 medium。
    static var recapTranscript: Font { scaledFont(16, weight: .medium) }

    // 元信息层
    /// 元信息：日期·时长文本、说话人名、说明文。13 regular。
    static var recapMeta: Font { scaledFont(13) }
    /// 数字等宽：时间戳、时长、计数、行内代码。13 regular mono + tabular。
    static var recapMono: Font { scaledFont(13, design: .monospaced).monospacedDigit() }
    /// 徽标：状态胶囊、计数徽标。11 semibold。
    static var recapCaption: Font { scaledFont(11, weight: .semibold) }
}

// MARK: - 字距 / 行距枚举（取代散落的魔法数）

/// 字距按「角色」派生：大字越紧（负距），眉标正距（小帽字）。仅用于替换已存在的魔法数，不新增。
public enum Tracking {
    public static let display: CGFloat = -0.6
    public static let hero: CGFloat = -0.5
    public static let title: CGFloat = -0.3
    public static let titleS: CGFloat = -0.2
    public static let heading: CGFloat = -0.15
    public static let body: CGFloat = -0.1
    public static let eyebrow: CGFloat = 1.4   // 眉标 / 小帽字正距
    public static let caption: CGFloat = 0.2
    public static let none: CGFloat = 0
}

/// 行距按「角色」派生：标题紧凑、正文 ~1.45x、TL;DR 高管摘要留白。
public enum Leading {
    public static let tight: CGFloat = 2       // 标题 / 单行
    public static let body: CGFloat = 5        // 16pt 阅读正文 ≈1.45x
    public static let relaxed: CGFloat = 6.5   // 仅 TL;DR 高管摘要留白
}

public enum Spacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 24
    public static let xxxl: CGFloat = 32
    public static let huge: CGFloat = 48
}

public enum Radius {
    public static let card: CGFloat = 16
    public static let stage: CGFloat = 28
    public static let sheet: CGFloat = 24
    public static let island: CGFloat = 999

    /// 同心内芯半径 = 外壳半径 - 内衬。四周等距 inset 时 continuous 圆角内外自动同心，
    /// 本 token 把这条不变式写死，防未来手写半径漂移。
    public static func concentric(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(0, outer - inset)
    }
}

/// 双层容器（Double-Bezel）几何常量：外壳(壳底+hairline) → inset → 内芯(纸面+顶部反光)。
/// 内芯半径一律取 `Radius.concentric`，与外壳数学同心。
public enum Bezel {
    /// 壳内衬：外壳与内芯之间的机加工留隙。
    public static let inset: CGFloat = 6
    /// hairline 宽（内外一致）。
    public static let hairline: CGFloat = 0.8
    /// 草稿卡外壳半径：内芯即 Radius.card(16)，与普通行卡片同半径，列表韵律不被打破。
    public static let draftOuter: CGFloat = Radius.card + inset   // 22
    /// 草稿卡内芯半径（= Radius.card，同心）。
    public static let draftCore: CGFloat = Radius.concentric(outer: draftOuter, inset: inset)
}

public extension View {
    /// 卡片投影：全站一档。只加在形状上，避免连正文一起投影导致文字发虚。
    func recapCardShadow() -> some View {
        shadow(color: .recapShadow, radius: 10, x: 0, y: 4)
    }

    /// 纸面落影：极轻双层——贴桌接触影（极小半径，仅勾出纸边）+ 环境柔影（低透明度大柔化）。
    /// 纸的物性靠颗粒与纸边（recapPaperGrain + hairline），不靠影的厚度；
    /// 影一旦读出「厚」，纸就变成了「板」。只用于纸面组等大面积纸。
    func recapPaperShadow() -> some View {
        shadow(color: .black.opacity(0.028), radius: 0.8, x: 0, y: 0.4)
            .shadow(color: .recapShadow.opacity(0.6), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder
    func recapGlass(cornerRadius: CGFloat = Radius.card) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }

    /// 双层容器：内芯(纸面+顶光+内 hairline) → inset → 外壳(壳底+hairline)。
    /// 用于静态展示场景；需左滑裁切的卡片（如首页草稿卡）在 SwipeableMeetingRow 内置实现，
    /// 保证裁切形状与外壳同源。
    func recapBezel(outerRadius: CGFloat = Bezel.draftOuter) -> some View {
        let core = Radius.concentric(outer: outerRadius, inset: Bezel.inset)
        let coreShape = RoundedRectangle(cornerRadius: core, style: .continuous)
        let outerShape = RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
        return self
            .background(coreShape.fill(Color.recapPaper))
            .overlay(
                coreShape.strokeBorder(
                    LinearGradient(
                        colors: [Color.recapCoreGlow, .clear],
                        startPoint: .top, endPoint: .center
                    ),
                    lineWidth: Bezel.hairline
                )
            )
            .padding(Bezel.inset)
            .background(outerShape.fill(Color.recapShell))
            .overlay(outerShape.strokeBorder(Color.recapShellRing, lineWidth: Bezel.hairline))
    }

    /// 玻璃仅作背景，不参与命中测试。用于包含 TextField 等需接收点击的容器。
    func recapGlassBackground(cornerRadius: CGFloat = Radius.card) -> some View {
        background {
            if #available(iOS 26.0, *) {
                Color.clear
                    .glassEffect(
                        .regular,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .allowsHitTesting(false)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
    }
}

// MARK: - 纸纹（Paper Grain）

/// 设备灰白噪声纹理：静态生成一次，平铺铺出纸面颗粒。
/// 纸感 = 暖骨底色（recapBg 的温度）+ 颗粒（此处）+ 落影（recapPaperShadow），三者缺一不可。
public enum RecapPaperTexture {
    /// 128×128 灰度白噪声。
    public static let noise: UIImage = {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side)
        for i in pixels.indices { pixels[i] = UInt8.random(in: 0...255) }
        let image = pixels.withUnsafeMutableBytes { buffer -> UIImage? in
            guard
                let ctx = CGContext(
                    data: buffer.baseAddress,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ),
                let cgImage = ctx.makeImage()
            else { return nil }
            return UIImage(cgImage: cgImage)
        }
        return image ?? UIImage()
    }()
}

public extension View {
    /// 纸面颗粒：白噪声平铺的极淡 grain。画布 0.02–0.03、纸面 ≤0.015；
    /// 勿多层叠加（会脏），勿给小元素用（噪声密度在高频小面积上读成脏点）。
    /// grain 属于「纸」不属于「内容」——行在纸上滑动时颗粒静止，物理上是对的。
    func recapPaperGrain(_ opacity: Double) -> some View {
        overlay(
            Rectangle()
                .fill(Color(uiColor: UIColor(patternImage: RecapPaperTexture.noise)))
                .opacity(opacity)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - AI 输入栏统一皮肤（AgentAskBar ↔ AgentInvokeSheet 共用，保证一致）

/// 极简灵动输入栏边框与环境微光（Apple-grade 质感）
/// 摒弃粗重高饱和荧光蓝，采用通透纸底、细微环境阴影与极细润色边框。
public struct AIAuroraRing: View {
    let focused: Bool
    let reduceMotion: Bool
    public init(focused: Bool, reduceMotion: Bool) {
        self.focused = focused
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        Capsule(style: .continuous)
            .strokeBorder(
                focused
                    ? Color.recapInk.opacity(0.22)
                    : Color.recapInk.opacity(0.08),
                lineWidth: focused ? 1.2 : 0.8
            )
            .animation(.recapSoft, value: focused)
            .allowsHitTesting(false)
    }
}

public extension View {
    /// AI compose 栏统一皮肤：温润纸底 + 浮动微阴影 + 精致单像素微边框。
    /// AgentAskBar(底栏) 与 AgentInvokeSheet(对话窗) 输入栏共用——保证「底栏发问 → 对话窗回答」视觉连续、温润自洽。
    func aiComposeBarStyle(focused: Bool, reduceMotion: Bool) -> some View {
        background {
            Capsule(style: .continuous)
                .fill(Color.recapPaper)
                .shadow(
                    color: Color.recapShadow.opacity(focused ? 1.0 : 0.6),
                    radius: focused ? 10 : 6,
                    x: 0,
                    y: focused ? 4 : 2
                )
        }
        .overlay { AIAuroraRing(focused: focused, reduceMotion: reduceMotion) }
        .animation(.recapSoft, value: focused)
    }
}

public extension Animation {
    static let recapLand = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let recapSoft = Animation.spring(response: 0.30, dampingFraction: 0.90)
    static let recapSheet = Animation.spring(response: 0.40, dampingFraction: 0.85)
    /// 按压缩反馈：极短 100ms，超快干脆响应。
    static let recapPress = Animation.easeOut(duration: 0.10)
    /// 首页冷启动入场：快、ease-out，避免 spring 拖尾。
    static let recapHomeEnter = Animation.easeOut(duration: 0.16)
    /// 左滑露出操作：更跟手。
    static let recapSwipeOpen = Animation.spring(response: 0.30, dampingFraction: 0.82)
    /// 左滑收起：更快，系统响应要干脆。
    static let recapSwipeClose = Animation.spring(response: 0.22, dampingFraction: 0.88)
    /// LIVE 贴底跟随：短、ease-out，高频不拖沓。
    static let recapLiveFollow = Animation.easeOut(duration: 0.14)
    /// LIVE 暂停/录音底栏切换：仅 opacity，无位移。
    static let recapPhaseBar = Animation.easeOut(duration: 0.16)
    /// LIVE 声波形态变形：大波形 ↔ 紧凑细带，spring 轻微回弹更有机（非 opacity 切换）。
    static let recapSonicMorph = Animation.spring(response: 0.42, dampingFraction: 0.82)
    /// 底栏退场：比入场更快。
    static let recapBottomExit = Animation.easeOut(duration: 0.18)
    /// 设置行右侧取值换字：仅交叉淡入，不做位移。
    static let recapValueSwap = Animation.easeOut(duration: 0.20)
    /// 行内状态提示出入场。
    static let recapNotice = Animation.easeOut(duration: 0.18)
    /// LIVE 暂停/恢复统一切换时长：声波、状态点、状态文字共用，三态同步起止。
    static let recapPausePhase = Animation.easeInOut(duration: 0.4)
}

/// 全 App 统一按压：scale 0.98 + 100ms ease-out。
public struct RecapPressStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(.recapPress, value: configuration.isPressed)
    }
}

/// 列表行按压：指尖落纸的极淡墨染（无位移、无缩放、不变文字）——
/// 纸面组平面语言里最接近物理按压的反馈，平面化的行因此不「死」。
/// 用于首页会议行（SwipeableMeetingRow 内 Button）。
public struct RecapRowPressStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.recapInk.opacity(configuration.isPressed ? 0.045 : 0))
            .animation(.recapPress, value: configuration.isPressed)
    }
}

/// Tab 标签按压：仅压暗（opacity 0.6），不做 scale——避免与 matchedGeometry 下划线指示器互相挤压；
/// 100ms easeOut 即时回执。用于顶栏 Tab（reviewTabButton / noteTabButton / reviewNewNoteButton）。
public struct RecapTabPressStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.recapPress, value: configuration.isPressed)
    }
}
