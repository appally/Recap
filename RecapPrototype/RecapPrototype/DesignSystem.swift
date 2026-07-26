import SwiftUI
import UIKit

// MARK: - 动态颜色（light / dark 自适应）

private extension Color {
    /// 用浅色 / 暗色 hex 构造一个随系统外观自适应的 Color
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor(dynamicProvider: { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(Color(hex: dark))
                : UIColor(Color(hex: light))
        }))
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    // 表面 / 底
    static let recapBg = Color(light: 0xF4F5F0, dark: 0x161814)
    static let recapPaper = Color(light: 0xFBFAF5, dark: 0x1E211C)
    static let recapCurrentBg = Color(light: 0xFDFBF6, dark: 0x232720)

    // 墨色
    static let recapInk = Color(light: 0x1F2421, dark: 0xEDEDE6)
    static let recapTea = Color(light: 0x6E7468, dark: 0x9AA095)

    // 品牌 / 强调
    static let recapCeladon = Color(light: 0x7D9B76, dark: 0x8AAB83)
    static let recapCinnabar = Color(light: 0xC8463C, dark: 0xE15A4E)
    static let recapOchre = Color(light: 0xB6824A, dark: 0xC99659)

    /// 说话人色环（按出现顺序循环）
    static func speaker(_ i: Int) -> Color {
        let palette: [(UInt32, UInt32)] = [
            (0x7D9B76, 0x8AAB83), // 青瓷
            (0x5A7A99, 0x6B8FB0), // 靛蓝
            (0xB6824A, 0xC99659), // 赭石
            (0xC99A9F, 0xD9ACB1), // 藕粉
            (0x5C615A, 0x747B73), // 墨灰
        ]
        let (l, d) = palette[abs(i) % palette.count]
        return Color(light: l, dark: d)
    }
}

// MARK: - 字体层级（SF Pro Display / Text 分层 + tracking + tabular）

extension Font {
    // 大标题用 SF Pro Display（更精致的字形）
    static let recapLargeTitle = Font.system(size: 28, weight: .bold, design: .default)
        .leading(.tight)
    static let recapH1 = Font.system(size: 22, weight: .semibold, design: .default)
        .leading(.tight)

    // 润色行（主读层）：SF Pro Text，semibold，1.55 行高
    static let recapPolished = Font.system(size: 17, weight: .semibold, design: .default)
    static let recapTldr = Font.system(size: 18, weight: .semibold, design: .default)
    static let recapRaw = Font.system(size: 15, weight: .regular, design: .default)

    // 任务正文
    static let recapTask = Font.system(size: 16, weight: .regular, design: .default)
    static let recapTaskLow = Font.system(size: 16, weight: .regular, design: .default)

    // 小标题与元信息
    static let recapSection = Font.system(size: 13, weight: .semibold, design: .default)
    static let recapMeta = Font.system(size: 13, weight: .regular, design: .default)

    // 时间戳用等宽数字（避免跳动）
    static let recapTimestamp = Font.system(size: 12, weight: .regular, design: .monospaced)
        .monospacedDigit()
}

// MARK: - 间距 / 圆角 token（8pt 基准）

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum Radius {
    static let card: CGFloat = 14
    static let sheet: CGFloat = 24
}

// MARK: - Liquid Glass 封装（内容实色 / 控制 glass）

extension View {
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
}

// MARK: - 动效基调

extension Animation {
    static let recapLand = Animation.spring(response: 0.45, dampingFraction: 0.82) // 落地
    static let recapSoft = Animation.spring(response: 0.30, dampingFraction: 0.90) // 轻柔
    static let recapSheet = Animation.spring(response: 0.40, dampingFraction: 0.85) // sheet
}
