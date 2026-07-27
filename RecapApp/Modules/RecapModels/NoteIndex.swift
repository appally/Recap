import Foundation

/// 笔记层导航目标（由父视图解释）：switcher 下拉项点击后去哪。
public enum NoteTarget: Sendable, Hashable {
    /// 总结（默认选中 · inline 渲染）。对应 `meeting.latestSummaryOutput`。
    case summary
    /// 调研草稿：`AIOutput(.draft)` 的 id。
    case researchDraft(UUID)
    /// 进行中 / 挂起的 `AgentTask` id。
    case researchTask(UUID)
}

/// 笔记层下拉项：switcher 里的一条笔记。
public struct NoteItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let createdAt: Date
    public let target: NoteTarget

    public init(
        id: String,
        title: String,
        subtitle: String,
        systemImage: String,
        createdAt: Date,
        target: NoteTarget
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.createdAt = createdAt
        self.target = target
    }
}

/// 笔记层联邦索引：从 Meeting 已有的 outputs / agentTasks 组装 switcher 下拉项。
///
/// 设计同前 `MeetingKitIndex` 的 derived 架构，但收口为单一「笔记」语义：
/// 「总结」恒为第一条（默认选中 · inline 渲染），调研草稿与进行中任务按时间倒序其后。
/// 无新 SwiftData 根实体，全部从既有关系聚合。
public enum NoteIndex {
    private static let busyStates: Set<AgentTaskState> = [
        .queued, .running, .suspended, .awaitingApproval,
    ]

    /// 本场所有笔记（总结置顶）。
    public static func notes(from meeting: Meeting, runningTaskId: UUID? = nil) -> [NoteItem] {
        var items: [NoteItem] = [summaryItem(meeting)]
        items.append(contentsOf: draftItems(from: meeting))
        items.append(contentsOf: taskItems(from: meeting, runningTaskId: runningTaskId))
        return items
    }

    /// 除总结外的笔记数（用于 switcher 标题「总结 · 另 N 份」与角标）。
    public static func otherCount(from meeting: Meeting, runningTaskId: UUID? = nil) -> Int {
        max(0, notes(from: meeting, runningTaskId: runningTaskId).count - 1)
    }

    /// 是否存在总结之外的笔记（调研草稿 / 进行中任务）。
    public static func hasOtherNotes(from meeting: Meeting, runningTaskId: UUID? = nil) -> Bool {
        otherCount(from: meeting, runningTaskId: runningTaskId) > 0
    }

    // MARK: - Items

    private static func summaryItem(_ meeting: Meeting) -> NoteItem {
        let version = meeting.latestSummaryOutput?.version ?? 0
        let subtitle = version > 1 ? "v\(version)" : ""
        return NoteItem(
            id: "note-summary",
            title: "总结",
            subtitle: subtitle,
            systemImage: "doc.richtext",
            createdAt: meeting.startedAt,
            target: .summary
        )
    }

    private static func draftItems(from meeting: Meeting) -> [NoteItem] {
        meeting.outputs
            .filter { $0.kind == .draft }
            .sorted { $0.createdAt > $1.createdAt }
            .map { output in
                let draft = output.researchDraftPayload
                return NoteItem(
                    id: "note-draft-\(output.id.uuidString)",
                    title: draft?.title ?? "调研草稿",
                    subtitle: draft.map { $0.hasCitations ? "含来源 · 请核实" : "⚠︎ 无来源 · 请谨慎" } ?? "AI 附页",
                    systemImage: "lightbulb",
                    createdAt: output.createdAt,
                    target: .researchDraft(output.id)
                )
            }
    }

    private static func taskItems(from meeting: Meeting, runningTaskId: UUID?) -> [NoteItem] {
        meeting.agentTasks
            .filter { busyStates.contains($0.state) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { task in
                let inMemory = runningTaskId == task.id
                let title: String
                let subtitle: String
                switch task.state {
                case .suspended:
                    title = inMemory ? "调研已挂起" : "未完成的调研"
                    subtitle = inMemory ? "回来可续跑" : "可能已中断，点开查看"
                case .queued, .running, .awaitingApproval:
                    title = inMemory ? "调研进行中" : "未完成的调研"
                    subtitle = inMemory ? "进行中" : "可能已中断，点开查看"
                default:
                    title = "未完成的调研"
                    subtitle = task.objective
                }
                return NoteItem(
                    id: "note-task-\(task.id.uuidString)",
                    title: title,
                    subtitle: subtitle,
                    systemImage: "arrow.triangle.2.circlepath",
                    createdAt: task.updatedAt,
                    target: .researchTask(task.id)
                )
            }
    }
}
