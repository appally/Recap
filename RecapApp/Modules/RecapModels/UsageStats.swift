import Foundation

/// 用量统计（设置页看板 + 活动热力图的数据源）。
///
/// 纯值类型：对一组 `Meeting` 做按日聚合，不依赖 SwiftUI / SwiftData，便于单测。
/// 口径：排除 `phase == .live` 的草稿——其 `durationSeconds` 可能为 0 或部分值，
/// 会拉低「总使用时长」。`.review` 与 `.processing` 均计入。
public struct UsageStats: Equatable {
    /// 口径内会议数（= 录音总数）。
    public let recordingCount: Int
    /// 有录音的不同自然日数（= 使用天数）。
    public let activeDays: Int
    /// 口径内会议时长之和（秒）。
    public let totalSeconds: Double
    /// 每个自然日（`startOfDay`）→ 当天场数；热力图按日取色。
    public let dailyCounts: [Date: Int]

    public init(meetings: [Meeting]) {
        let valid = meetings.filter { $0.phase != .live }
        let calendar = Calendar.current
        var counts: [Date: Int] = [:]
        for meeting in valid {
            let day = calendar.startOfDay(for: meeting.startedAt)
            counts[day, default: 0] += 1
        }
        self.dailyCounts = counts
        self.recordingCount = valid.count
        self.activeDays = counts.count
        self.totalSeconds = valid.reduce(0) { $0 + $1.durationSeconds }
    }

    /// 热力图分档：0 空 / 1 → L1 / 2 → L2 / 3 → L3 / ≥4 → L4。
    public static func level(forDailyCount count: Int) -> Int {
        switch count {
        case 0:  return 0
        case 1:  return 1
        case 2:  return 2
        case 3:  return 3
        default: return 4
        }
    }
}
