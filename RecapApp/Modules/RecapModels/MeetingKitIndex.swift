import Foundation

/// 会册架：架构心智模型；Wave A UI 只渲染来料 + 衍生。
public enum MeetingKitShelf: String, Sendable, CaseIterable {
    case incoming
    case evidence
    case canonical
    case derived
}

/// 会册内导航目标（由父视图解释）。
public enum MeetingKitTarget: Sendable, Hashable {
    case briefHome
    case researchDraft(UUID)
    case researchTask(UUID)
    case regenerateWithBrief
}

public struct MeetingKitItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let shelf: MeetingKitShelf
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let createdAt: Date
    public let target: MeetingKitTarget

    public init(
        id: String,
        shelf: MeetingKitShelf,
        title: String,
        subtitle: String,
        systemImage: String,
        createdAt: Date,
        target: MeetingKitTarget
    ) {
        self.id = id
        self.shelf = shelf
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.createdAt = createdAt
        self.target = target
    }
}

/// 联邦索引：从 Meeting 已有关系组装会册条目（无新 SwiftData 根实体）。
public enum MeetingKitIndex {
    private static let busyStates: Set<AgentTaskState> = [
        .queued, .running, .suspended, .awaitingApproval,
    ]

    public static func build(from meeting: Meeting, runningTaskId: UUID? = nil) -> [MeetingKitItem] {
        var items: [MeetingKitItem] = []
        items.append(contentsOf: incomingItems(from: meeting))
        items.append(contentsOf: evidenceItems(from: meeting))
        items.append(contentsOf: canonicalItems(from: meeting))
        items.append(contentsOf: makeDerivedItems(from: meeting, runningTaskId: runningTaskId))
        return items
    }

    public static func chipLabel(for meeting: Meeting, runningTaskId: UUID? = nil) -> String {
        let items = build(from: meeting, runningTaskId: runningTaskId)
        let count = incomingCount(in: items) + derivedCount(in: items)
        if count == 0 { return "资料·未添加" }
        return "资料·\(count)"
    }

    /// 资料窗是否视为「有内容」（来料或 AI 附页）。
    public static func hasMaterials(for meeting: Meeting, runningTaskId: UUID? = nil) -> Bool {
        let items = build(from: meeting, runningTaskId: runningTaskId)
        return incomingCount(in: items) + derivedCount(in: items) > 0
    }

    public static func derivedCount(in items: [MeetingKitItem]) -> Int {
        items.filter { $0.shelf == .derived }.count
    }

    public static func incomingCount(in items: [MeetingKitItem]) -> Int {
        items.filter { $0.shelf == .incoming }.count
    }

    // MARK: - Shelves

    private static func incomingItems(from meeting: Meeting) -> [MeetingKitItem] {
        guard let brief = meeting.brief else { return [] }
        if brief.sources.isEmpty {
            // 有议程/遗留但尚无 source 记录时，仍计 1 条来料占位（chip 用）
            if !brief.agenda.isEmpty || !brief.openItems.isEmpty {
                return [
                    MeetingKitItem(
                        id: "brief-structure-\(brief.id.uuidString)",
                        shelf: .incoming,
                        title: "会前结构",
                        subtitle: brief.chipLabelLegacyStructure,
                        systemImage: BriefRole.agenda.systemImageName,
                        createdAt: brief.updatedAt,
                        target: .briefHome
                    ),
                ]
            }
            return []
        }
        return brief.sources.map { source in
            MeetingKitItem(
                id: "brief-source-\(source.id.uuidString)",
                shelf: .incoming,
                title: source.title,
                subtitle: source.role.displayName,
                systemImage: source.role.systemImageName,
                createdAt: source.createdAt,
                target: .briefHome
            )
        }
    }

    private static func evidenceItems(from meeting: Meeting) -> [MeetingKitItem] {
        var items: [MeetingKitItem] = []
        if !meeting.segments.isEmpty {
            items.append(
                MeetingKitItem(
                    id: "evidence-transcript-\(meeting.id.uuidString)",
                    shelf: .evidence,
                    title: "转写",
                    subtitle: "\(meeting.segments.count) 段",
                    systemImage: "text.alignleft",
                    createdAt: meeting.startedAt,
                    target: .briefHome
                )
            )
        }
        if let path = meeting.audioPath, !path.isEmpty {
            items.append(
                MeetingKitItem(
                    id: "evidence-audio-\(meeting.id.uuidString)",
                    shelf: .evidence,
                    title: "录音",
                    subtitle: "本地音频",
                    systemImage: "waveform",
                    createdAt: meeting.startedAt,
                    target: .briefHome
                )
            )
        }
        return items
    }

    private static func canonicalItems(from meeting: Meeting) -> [MeetingKitItem] {
        var items: [MeetingKitItem] = []
        if let summary = meeting.latestSummaryOutput {
            items.append(
                MeetingKitItem(
                    id: "canonical-summary-\(summary.id.uuidString)",
                    shelf: .canonical,
                    title: "纪要",
                    subtitle: "v\(summary.version)",
                    systemImage: "doc.richtext",
                    createdAt: summary.createdAt,
                    target: .briefHome
                )
            )
        }
        if !meeting.actionItems.isEmpty {
            items.append(
                MeetingKitItem(
                    id: "canonical-todos-\(meeting.id.uuidString)",
                    shelf: .canonical,
                    title: "待办",
                    subtitle: "\(meeting.actionItems.count) 条",
                    systemImage: "checklist",
                    createdAt: meeting.startedAt,
                    target: .briefHome
                )
            )
        }
        return items
    }

    private static func makeDerivedItems(from meeting: Meeting, runningTaskId: UUID?) -> [MeetingKitItem] {
        var items: [MeetingKitItem] = []

        let drafts = meeting.outputs
            .filter { $0.kind == .draft }
            .sorted { $0.createdAt > $1.createdAt }
        for output in drafts {
            let title = output.researchDraftPayload?.title ?? "调研草稿"
            let subtitle: String
            if let draft = output.researchDraftPayload {
                subtitle = draft.hasCitations ? "含来源 · 请核实" : "⚠︎ 无来源 · 请谨慎使用"
            } else {
                subtitle = "AI 附页"
            }
            items.append(
                MeetingKitItem(
                    id: "derived-draft-\(output.id.uuidString)",
                    shelf: .derived,
                    title: title,
                    subtitle: subtitle,
                    systemImage: "lightbulb",
                    createdAt: output.createdAt,
                    target: .researchDraft(output.id)
                )
            )
        }

        let busyTasks = meeting.agentTasks
            .filter { busyStates.contains($0.state) }
            .sorted { $0.updatedAt > $1.updatedAt }
        for task in busyTasks {
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
            items.append(
                MeetingKitItem(
                    id: "derived-task-\(task.id.uuidString)",
                    shelf: .derived,
                    title: title,
                    subtitle: subtitle,
                    systemImage: "arrow.triangle.2.circlepath",
                    createdAt: task.updatedAt,
                    target: .researchTask(task.id)
                )
            )
        }

        return items
    }
}

extension MeetingBrief {
    /// Index 在无 sources 时的结构摘要（不改对外 chip 主路径）。
    fileprivate var chipLabelLegacyStructure: String {
        var parts: [String] = []
        if !agenda.isEmpty { parts.append("议程\(agenda.count)项") }
        if !openItems.isEmpty { parts.append("遗留\(openItems.count)") }
        return parts.isEmpty ? "已添加" : parts.joined(separator: "·")
    }
}
