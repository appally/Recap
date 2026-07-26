import UIKit

/// 全 App 统一触感入口。
///
/// 设计意图（对应《视觉与UX》calm 哲学）：
/// - **impact**：操作即时反馈（按下了、听到了）。语义强度 light→medium，操作越核心越重。
/// - **selection**：状态切换（勾选、Tab、分段）。最轻，一天可触发多次而不烦。
/// - **notify**：结果交付（纪要就绪、分发成败、复制成功）。低频、有信息量，配得上一次明确震感。
///
/// 全部走静态 generator 并在每次触发后 `prepare()` 预热下一次，避免冷启动延迟——
/// 这是原来散落各处的 `UIImpactFeedbackGenerator().impactOccurred()` 最大的体感问题。
///
/// `@MainActor`：UIKit 反馈生成器是主线程隔离类型，初始化与触发都在主 actor；
/// 所有调用点本就在 SwiftUI 的 @MainActor 上下文（View body / Button action / onChange）。
@MainActor
public enum Haptics {

    public enum Impact {
        case light, medium, soft, heavy
    }

    public enum Notice {
        case success, warning, error
        fileprivate var uiType: UINotificationFeedbackGenerator.FeedbackType {
            switch self {
            case .success: return .success
            case .warning: return .warning
            case .error: return .error
            }
        }
    }

    /// 每种 style 独立 generator（Apple 推荐做法：系统可针对不同强度分别调优），
    /// 并在每次触发后立即 prepare 预热下一次，避免冷启动延迟。
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let noticeGenerator = UINotificationFeedbackGenerator()

    /// 在即将进入一段密集交互（如拍照连拍、拖拽）前调用，提前暖机。
    public static func prepare() {
        lightGenerator.prepare()
        mediumGenerator.prepare()
        softGenerator.prepare()
        heavyGenerator.prepare()
        selectionGenerator.prepare()
        noticeGenerator.prepare()
    }

    /// 操作反馈。核心动作用 `.medium`，常规次级用 `.light`，破坏性前奏用 `.heavy`。
    public static func impact(_ style: Impact) {
        let generator: UIImpactFeedbackGenerator
        switch style {
        case .light: generator = lightGenerator
        case .medium: generator = mediumGenerator
        case .soft: generator = softGenerator
        case .heavy: generator = heavyGenerator
        }
        generator.impactOccurred()
        generator.prepare()
    }

    /// 状态切换（勾选 / Tab / 分段控件）。最轻。
    public static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    /// 结果通知（成功 / 警告 / 失败）。低频、有语义，始终触发——reduceMotion 不静音结果。
    public static func notify(_ kind: Notice) {
        noticeGenerator.notificationOccurred(kind.uiType)
        noticeGenerator.prepare()
    }
}
