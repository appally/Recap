import Foundation
import RecapModels

/// 跨会议世界查询（协议倒置：`RecapLLM` 不依赖 `RecapPersistence`）。
public protocol AgentWorkspaceQuerying: Sendable {
    /// 关键词 + 可选时间范围检索会议（**排除 excluding**）。
    func searchMeetings(
        query: String,
        excluding: UUID?,
        since: Date?,
        limit: Int
    ) async -> [MeetingCard]

    /// 指定会议内的转写检索。
    func searchTranscript(
        meetingId: UUID,
        query: String,
        limit: Int
    ) async -> [TranscriptHit]

    /// 指定会议纪要（最高 version）。
    func minutes(meetingId: UUID) async -> MeetingSummary?

    /// 待办；`meetingId == nil` 且 `openOnly` 时扫全部未完成。
    func actionItems(
        meetingId: UUID?,
        openOnly: Bool,
        limit: Int
    ) async -> [ActionItemSnapshot]

    /// 会议展示标签（短日期 + 标题）；不存在则 nil。
    func meetingLabel(meetingId: UUID) async -> String?
}
