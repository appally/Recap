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

    /// 纯净静谧纸底：高级冷瓷灰/黑曜石底色，无黄绿杂浊感。
    static let recapBg = Color(light: 0xF8F9FA, dark: 0x0C0E11)
    static let recapPaper = Color(light: 0xFFFFFF, dark: 0x16191D)
    static let recapCurrentBg = Color(light: 0xFFFFFF, dark: 0x1C2025)

    static let recapInk = Color(light: 0x111614, dark: 0xF0F2EE)
    static let recapTea = Color(light: 0x6E7671, dark: 0x9CA29A)

    /// 投影专用色。通透自然的软阴影，避免脏发灰。
    static let recapShadow = Color(light: 0x000000, lightAlpha: 0.04, dark: 0x000000, darkAlpha: 0.28)

    /// 中性强调色（原青瓷品牌色已退役）。全 App 走黑白灰中性体系：
    /// 强调靠 recapInk 的深浅 + 字重层次，不靠彩色。此 token 保留命名以免改 133 处引用，
    /// 但语义已等价于 recapInk（墨黑）。朱砂/赭石仅作不可替代的功能语义保留。
    static let recapCeladon = Color(light: 0x111614, dark: 0xF0F2EE)
    static let recapCinnabar = Color(light: 0xC8463C, dark: 0xE15A4E)
    static let recapOchre = Color(light: 0xA87842, dark: 0xC99659)

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
}

public extension Font {
    /// Plaud 杂志风格大标题（全部文件 ∨ 等）
    static let recapHeroTitle = Font.system(size: 32, weight: .bold, design: .default)
        .leading(.tight)
    /// 首页品牌英雄字。
    static let recapHomeBrand = Font.system(size: 32, weight: .bold, design: .default)
    /// 眉题 / 小徽记。
    static let recapBrand = Font.system(size: 13, weight: .semibold, design: .rounded)
    /// 首页日期英雄字。
    static let recapDisplay = Font.system(size: 34, weight: .semibold, design: .default)
        .leading(.tight)
    static let recapLargeTitle = Font.system(size: 28, weight: .bold, design: .default)
        .leading(.tight)
    static let recapH1 = Font.system(size: 22, weight: .semibold, design: .default)
        .leading(.tight)

    /// 润色行（有别于原话时）：略加重，作主读。
    static let recapPolished = Font.system(size: 17, weight: .semibold, design: .default)
    /// LIVE / 单行字幕：中等字重，长读不糊成标题。
    static let recapTranscript = Font.system(size: 17, weight: .medium, design: .default)
    static let recapTldr = Font.system(size: 18, weight: .semibold, design: .default)
    static let recapRaw = Font.system(size: 15, weight: .regular, design: .default)

    static let recapTask = Font.system(size: 16, weight: .regular, design: .default)
    static let recapTaskLow = Font.system(size: 16, weight: .regular, design: .default)

    static let recapSection = Font.system(size: 12, weight: .semibold, design: .default)
    static let recapMeta = Font.system(size: 13, weight: .regular, design: .default)
    /// 极简内联元数据（19:43 | 16分钟）
    static let recapSubMeta = Font.system(size: 13, weight: .regular, design: .default)

    static let recapTimestamp = Font.system(size: 12, weight: .regular, design: .monospaced)
        .monospacedDigit()
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
}

public extension View {
    /// 卡片投影：全站一档。只加在形状上，避免连正文一起投影导致文字发虚。
    func recapCardShadow() -> some View {
        shadow(color: .recapShadow, radius: 10, x: 0, y: 4)
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
    /// 底栏退场：比入场更快。
    static let recapBottomExit = Animation.easeOut(duration: 0.18)
    /// 设置行右侧取值换字：仅交叉淡入，不做位移。
    static let recapValueSwap = Animation.easeOut(duration: 0.20)
    /// 行内状态提示出入场。
    static let recapNotice = Animation.easeOut(duration: 0.18)
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
