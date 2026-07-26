import Foundation

/// 跨会议检索候选卡（轻量，不含转写正文）。
public struct MeetingCard: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let startedAt: Date
    public let durationSeconds: Double
    public let tldr: String?
    public let openQuestionCount: Int
    public let actionItemCount: Int
    /// 命中原因，回填给模型判断是否进入该场会。
    public let matchReason: String

    public init(
        id: UUID,
        title: String,
        startedAt: Date,
        durationSeconds: Double,
        tldr: String?,
        openQuestionCount: Int,
        actionItemCount: Int,
        matchReason: String
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.tldr = tldr
        self.openQuestionCount = openQuestionCount
        self.actionItemCount = actionItemCount
        self.matchReason = matchReason
    }

    public var dateText: String {
        startedAt.formatted(
            Date.FormatStyle()
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .locale(Locale(identifier: "zh_CN"))
        )
    }

    public var shortDateText: String {
        startedAt.formatted(
            Date.FormatStyle()
                .month(.twoDigits)
                .day(.twoDigits)
                .locale(Locale(identifier: "zh_CN"))
        )
    }
}

/// 待办值快照（Sendable，供工具与跨模块使用）。
public struct ActionItemSnapshot: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let task: String
    public let owner: String?
    public let dueText: String?
    public let statusRaw: String
    public let meetingTitle: String
    public let isDispatched: Bool

    public init(
        id: UUID,
        task: String,
        owner: String? = nil,
        dueText: String? = nil,
        statusRaw: String,
        meetingTitle: String,
        isDispatched: Bool
    ) {
        self.id = id
        self.task = task
        self.owner = owner
        self.dueText = dueText
        self.statusRaw = statusRaw
        self.meetingTitle = meetingTitle
        self.isDispatched = isDispatched
    }
}
