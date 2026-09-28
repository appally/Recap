import SwiftUI

// MARK: - 语义图标字典

/// Recap 全站 SF Symbol 语义表。
///
/// 原则：
/// 1. **Outline 优先**（顶栏 glass 圆钮里 filled 易糊成色块）
/// 2. **一事一符**：资料≠文档、AI≠魔法棒乱飞、回听≠播放
/// 3. **字重统一**：顶栏 15pt semibold；列表行 16pt medium；菜单随系统
/// 4. **禁堆叠变体**：避免 `*.circle.fill` 套进已有圆形 glass 钮（双重圆）
public enum RecapSymbol {
    // 本场能力
    /// 资料：桌上的一叠纸，而非通用「单页文档」。
    public static let materials = "rectangle.stack"
    public static let ask = "sparkles"
    public static let listen = "headphones"
    /// 会中拍照记录此刻（白板 / 想法 / 此刻快照）。
    public static let camera = "camera"
    /// 会中手写（Apple Pencil 画布）—— 与「记录此刻」同属底部动作坞。
    public static let handwrite = "pencil.line"
    public static let stop = "stop.fill"
    public static let share = "square.and.arrow.up"
    public static let add = "plus"
    public static let more = "ellipsis"
    public static let close = "xmark"
    public static let back = "chevron.left"
    public static let chevron = "chevron.right"
    public static let delete = "trash"
    public static let check = "checkmark"
    public static let play = "play.fill"
    public static let pause = "pause.fill"
    /// LIVE「回到最新」：最新字幕在底部，箭头向下。
    public static let scrollToLatest = "arrow.down"
    /// 搜索（独立搜索界面入口）。
    public static let search = "magnifyingglass"

    // 资料动作
    public static let scan = "doc.viewfinder"
    public static let paste = "doc.on.clipboard"
    /// 导入外部音频：plus（几何中心=光学中心，与 search 单笔画同重量同轴）。
    /// 弃 square.and.arrow.down——方形沉底箭头压顶，重心偏下，且与放大镜重量不齐。
    public static let importAudio = "plus"
    public static let linkPrior = "link"
    public static let research = "sparkles"
    public static let researchProgress = "arrow.triangle.2.circlepath"
    public static let researchDraft = "lightbulb"

    // 会前角色（与 BriefRole 对齐，供 UI 层使用）
    public static let roleAgenda = "list.bullet.rectangle"
    public static let rolePrior = "clock.arrow.circlepath"
    public static let roleProposal = "doc.richtext"
    public static let roleRoster = "person.3"
    public static let roleNotes = "note.text"
    public static let roleLinked = "link"

    // Ask
    public static let web = "globe"
    public static let send = "arrow.up"

    // 其它
    public static let waveform = "waveform"
    /// 首页账户入口（outline，与顶栏 glass 圆钮同规）。
    public static let account = "person"
    public static let person = "person"
    public static let info = "info.circle"
    /// 设置 / 关于与合规入口（顶栏齿轮，区别于首页 account 的人像）。
    public static let settings = "gearshape"
}

// MARK: - 顶栏 glass 圆钮（统一视觉）

public enum RecapToolbarIconMetrics {
    public static let side: CGFloat = 44
    public static let pointSize: CGFloat = 17
    public static let weight: Font.Weight = .medium
    public static let inkOpacity: Double = 0.85
    public static let accentOpacity: Double = 0.95
    public static let dot: CGFloat = 7
    public static let dotOffset = CGSize(width: -7, height: 9)
}

/// 顶栏图标的裸像：SF Symbol + 统一字重 / 墨色 + 44pt 圆形命中区，不带任何玻璃。
/// 既供玻璃圆钮 `RecapToolbarIconLabel` 复用，也供胶囊内裸图标（如「分享·更多」共胶囊时）复用——
/// 胶囊里再套玻璃圆会造成双像，故共胶囊段用裸像，玻璃统一由外层胶囊提供。
public struct RecapToolbarIconImage: View {
    public var systemName: String
    public var emphasized: Bool

    public init(_ systemName: String, emphasized: Bool = false) {
        self.systemName = systemName
        self.emphasized = emphasized
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: RecapToolbarIconMetrics.pointSize, weight: RecapToolbarIconMetrics.weight))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(
                emphasized
                    ? Color.recapInk
                    : Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity)
            )
            .frame(width: RecapToolbarIconMetrics.side, height: RecapToolbarIconMetrics.side)
            .contentShape(Circle())
    }
}

/// 顶栏圆形图标的统一标签 = `RecapToolbarIconImage` + Liquid Glass 圆（+ 可选角标）。
/// 与底栏 `RecapGlassAuxIcon` 同材质；作为 `Button` / `ShareLink` / `Menu` 的 label 复用，
/// 让首页 toolbar 项与纪要顶栏独立角图标同形 · 同材 · 同尺寸。
public struct RecapToolbarIconLabel: View {
    public var systemName: String
    public var emphasized: Bool
    public var hasBadge: Bool

    public init(_ systemName: String, emphasized: Bool = false, hasBadge: Bool = false) {
        self.systemName = systemName
        self.emphasized = emphasized
        self.hasBadge = hasBadge
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            RecapToolbarIconImage(systemName, emphasized: emphasized)
                .glassEffect(.regular.interactive(), in: .circle)
            if hasBadge {
                Circle()
                    .fill(Color.recapCinnabar)
                    .frame(width: RecapToolbarIconMetrics.dot, height: RecapToolbarIconMetrics.dot)
                    .offset(x: RecapToolbarIconMetrics.dotOffset.width,
                            y: RecapToolbarIconMetrics.dotOffset.height)
            }
        }
    }
}

/// 顶栏圆形入口按钮：资料 / Ask / 搜索 / 账户 等共用。视觉走 `RecapToolbarIconLabel`（Liquid Glass 圆）。
/// 用于 toolbar 项时，配 `.sharedBackgroundVisibility(.hidden)` 关掉系统玻璃，只留此处自绘玻璃，避免双像。
public struct RecapToolbarIcon: View {
    public var systemName: String
    public var emphasized: Bool = false
    public var hasBadge: Bool = false
    public var accessibilityLabel: String
    public var accessibilityHint: String? = nil
    public var action: () -> Void

    public init(
        _ systemName: String,
        emphasized: Bool = false,
        hasBadge: Bool = false,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.emphasized = emphasized
        self.hasBadge = hasBadge
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            RecapToolbarIconLabel(systemName, emphasized: emphasized, hasBadge: hasBadge)
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
    }
}

// MARK: - 纪要底栏 AI 入口（LIVE / REVIEW 共用）

private final class AIAvatarBundleFinder {}

/// AI Avatar 图像组件，兼具 Bundle 动态加载与备用路径降级。
public struct RecapAIAvatarImage: View {
    public var size: CGFloat? = nil

    public init(size: CGFloat? = nil) {
        self.size = size
    }

    public var body: some View {
        Group {
            if let uiImage = loadAIAvatarUIImage() {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image("avater")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
    }

    private func loadAIAvatarUIImage() -> UIImage? {
        if let img = UIImage(named: "avater", in: Bundle(for: AIAvatarBundleFinder.self), compatibleWith: nil) {
            return img
        }
        if let img = UIImage(named: "avater", in: .main, compatibleWith: nil) {
            return img
        }
        if let img = UIImage(named: "avater") {
            return img
        }
        return nil
    }
}

// MARK: - 底栏玻璃圆辅助钮（LIVE 左右槽共用）

/// 底栏左右辅助槽的统一视觉：SF Symbol + Liquid Glass 圆形容器。
/// 「记录此刻」(camera) 与「问 Recap」(sparkles) 共用同一规格——
/// 同形 / 同材 / 同尺寸 / 同字重，与中央实心主控构成
/// 「玻璃(辅) · 实心(主) · 玻璃(辅)」的清晰层级。
public struct RecapGlassAuxIcon: View {
    public let systemName: String
    public var size: CGFloat

    public init(_ systemName: String, size: CGFloat = 52) {
        self.systemName = systemName
        self.size = size
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 19, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.recapInk.opacity(0.72))
            .frame(width: size, height: size)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// 列表 / 卡片左侧语义图标（非圆形套圆）。
public struct RecapRowIcon: View {
    public var systemName: String
    public var tint: Color = Color.recapInk.opacity(0.55)

    public init(_ systemName: String, tint: Color = Color.recapInk.opacity(0.55)) {
        self.systemName = systemName
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(tint)
            .frame(width: 22, alignment: .center)
            .accessibilityHidden(true)
    }
}
