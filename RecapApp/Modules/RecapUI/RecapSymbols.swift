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
    public static let share = "square.and.arrow.up"
    public static let add = "plus"
    public static let more = "ellipsis"
    public static let close = "xmark"
    public static let back = "chevron.left"
    public static let dismissDown = "chevron.down"
    public static let chevron = "chevron.right"
    public static let delete = "trash"
    public static let check = "checkmark"
    public static let play = "play.fill"
    public static let pause = "pause.fill"
    public static let scrollToLatest = "arrow.down"

    // 资料动作
    public static let scan = "doc.viewfinder"
    public static let paste = "doc.on.clipboard"
    public static let importFile = "square.and.arrow.down"
    public static let linkPrior = "link"
    public static let research = "sparkles.magnifyingglass"
    public static let researchProgress = "arrow.triangle.2.circlepath"
    public static let researchDraft = "lightbulb"

    // 会前角色（与 BriefRole 对齐，供 UI 层使用）
    public static let roleAgenda = "list.bullet.rectangle"
    public static let rolePrior = "clock.arrow.circlepath"
    public static let roleProposal = "doc.richtext"
    public static let roleRoster = "person.3"
    public static let roleNotes = "note.text"
    public static let roleLinked = "link"

    // Ask / Skills
    public static let skills = "wand.and.stars"
    public static let web = "globe"
    public static let revise = "pencil"
    public static let newChat = "square.and.pencil"
    public static let send = "arrow.up"

    // 其它
    public static let waveform = "waveform"
    /// 首页账户入口（outline，与顶栏 glass 圆钮同规）。
    public static let account = "person"
    public static let person = "person"
    public static let info = "info.circle"
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

/// 纪要顶栏圆形入口：资料 / Ask / 回听 / 分享 等共用。
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
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: RecapToolbarIconMetrics.pointSize, weight: RecapToolbarIconMetrics.weight))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(
                        emphasized
                            ? Color.recapCeladon
                            : Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity)
                    )
                    .frame(width: RecapToolbarIconMetrics.side, height: RecapToolbarIconMetrics.side)
                    .contentShape(Circle())
                if hasBadge {
                    Circle()
                        .fill(Color.recapCinnabar)
                        .frame(width: RecapToolbarIconMetrics.dot, height: RecapToolbarIconMetrics.dot)
                        .offset(x: RecapToolbarIconMetrics.dotOffset.width,
                                y: RecapToolbarIconMetrics.dotOffset.height)
                }
            }
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
        if let img = UIImage(contentsOfFile: "/Users/liuyong/Projects/Recap/avater.png") {
            return img
        }
        return nil
    }
}

/// 纪要底栏「问 Recap」入口视觉（LIVE / REVIEW 共用）。
/// 纪要底栏「问 Recap」入口视觉（通透纯净玻璃 AI 按钮，搭载 AI Avatar Icon）。
public struct RecapAskEntryLabel: View {
    public var size: CGFloat = 52

    public init(size: CGFloat = 52) {
        self.size = size
    }

    public var body: some View {
        ZStack(alignment: .center) {
            RecapAIAvatarImage(size: size * 0.64)
                .clipShape(Circle())
                .accessibilityHidden(true)
        }
        .frame(width: size, height: size, alignment: .center)
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
