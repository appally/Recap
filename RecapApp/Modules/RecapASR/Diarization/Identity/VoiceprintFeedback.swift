import Foundation
import os

/// 声纹匹配的用户反馈校准（声纹升级方案 Step 4a）。
///
/// 原理：用户的纠错行为 = 免费的 ground truth——两个信号都指向「匹配过窄（漏并）」：
/// - 「合并两位说话人」：系统把同一个人拆成了两条 → 拆分错误，应**放宽**阈值。
///   （原实现取 +0.05 收紧是错误归因——用户越合并阈值越高、拆分越多，正反馈恶性循环；
///   误并=匹配过宽的修正入口是「拆分」，UI 中不存在，不会走到这里。）
/// - 「手动给新说话人归名」：系统没认出已知成员 → 同为漏并信号，放宽（幅度更轻）。
/// 全部本地启发式，无训练、无云端；阈值调整只影响后续会议匹配，可随时重置。
///
/// 线程模型：`thresholdAdjustment` 会在 IdentityMatcher actor（后台）被调用，
/// `recordMerge`/`recordManualAssign`/`reset` 在 UI/测试线程被调用——跨线程互斥。
/// 用 `OSAllocatedUnfairLock`（Swift 6 推荐；NSLock 在 Swift 并发跨线程获取/释放是已知陷阱，
/// 曾在测试中造成持锁线程与 actor 线程死锁）。
public final class VoiceprintFeedback: @unchecked Sendable {
    public static let shared = VoiceprintFeedback()

    private enum Key {
        static let mergeCount = "recap.voiceprint.feedback.mergeCount"
        static let manualAssignCount = "recap.voiceprint.feedback.manualAssignCount"
    }

    /// 每次用户合并操作对 AS-Norm 阈值的减量（放宽漏并；合并 = 系统拆分了同一人）。
    public static let mergeReliefPerEvent: Float = -0.05
    /// 每次用户手动归名对 AS-Norm 阈值的减量（放宽漏并，幅度更轻）。
    public static let manualAssignReliefPerEvent: Float = 0.02
    /// 阈值调整的上下限（z-score 量级；上限留给未来的「拆分=误并」收紧信号）。
    public static let adjustmentClamp: ClosedRange<Float> = (-0.5)...(0.75)

    private let lock = OSAllocatedUnfairLock()

    public var mergeCount: Int {
        lock.withLock { UserDefaults.standard.integer(forKey: Key.mergeCount) }
    }

    public var manualAssignCount: Int {
        lock.withLock { UserDefaults.standard.integer(forKey: Key.manualAssignCount) }
    }

    /// 用户确认「这两位其实是同一个人」（画廊 merge 时调用）。
    public func recordMerge() {
        lock.withLock {
            let v = UserDefaults.standard.integer(forKey: Key.mergeCount) + 1
            UserDefaults.standard.set(v, forKey: Key.mergeCount)
        }
    }

    /// 用户手动给一个未自动命中的说话人归名（SpeakerPicker 选中已有画廊成员时调用）。
    public func recordManualAssign() {
        lock.withLock {
            let v = UserDefaults.standard.integer(forKey: Key.manualAssignCount) + 1
            UserDefaults.standard.set(v, forKey: Key.manualAssignCount)
        }
    }

    /// 净阈值调整量：merge 与 manualAssign 均为漏并信号（放宽，前者幅度大），clamp 到安全区间。
    /// - Returns: 加到 `IdentityMatchConfig.asNormThreshold` 上的调整量（≤0）。
    public func thresholdAdjustment() -> Float {
        // 单次 withLock 内直接读 UserDefaults（unfair lock 不可重入，勿嵌套 getter）。
        lock.withLock {
            let merges = UserDefaults.standard.integer(forKey: Key.mergeCount)
            let assigns = UserDefaults.standard.integer(forKey: Key.manualAssignCount)
            let raw = Float(merges) * Self.mergeReliefPerEvent
                - Float(assigns) * Self.manualAssignReliefPerEvent
            return min(max(raw, Self.adjustmentClamp.lowerBound), Self.adjustmentClamp.upperBound)
        }
    }

    /// 重置全部反馈记录（设置页「恢复默认匹配灵敏度」）。
    public func reset() {
        lock.withLock {
            UserDefaults.standard.removeObject(forKey: Key.mergeCount)
            UserDefaults.standard.removeObject(forKey: Key.manualAssignCount)
        }
    }
}