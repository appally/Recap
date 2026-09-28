import ActivityKit
import Foundation

// MARK: - 录音 Live Activity 属性（plan 054）

/// 两端共享：主 App（RecapUI/MeetingSession）请求与更新，Controls 扩展（灵动岛/锁屏）渲染。
///
/// 隐私红线（plan 054）：静态属性与 ContentState 均不放会议标题 / 地点 / 转写内容——
/// 锁屏与灵动岛可能被旁人看到。
public struct RecordingActivityAttributes: ActivityAttributes {
    /// 显式 Sendable：`ActivityContent` 的条件 Sendable 依赖它，Swift 6 complete 下
    /// 跨隔离域 update/end 才能通过。
    public struct ContentState: Codable & Hashable & Sendable {
        /// 本段录音起点（= 更新时刻 - 已累计秒数），配合 `Text(.timer)` 自走计时，
        /// 无需高频推送；暂停时渲染端据此换算冻结时长。
        public var startedAt: Date
        public var isPaused: Bool
        /// 预留：055 声纹在场（"王总 · 还有未识别的声音"），v1 恒 nil。
        public var speakerSummary: String?

        public init(startedAt: Date, isPaused: Bool, speakerSummary: String? = nil) {
            self.startedAt = startedAt
            self.isPaused = isPaused
            self.speakerSummary = speakerSummary
        }

        /// 当前累计秒（暂停时 = 冻结在暂停瞬间的值，因为不再推送更新）。
        public var elapsedSeconds: Int {
            Int(Date().timeIntervalSince(startedAt))
        }
    }

    public init() {}
}
