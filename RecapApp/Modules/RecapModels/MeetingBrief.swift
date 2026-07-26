import Foundation
import SwiftData

// MARK: - Value types（JSON blob，与 TranscriptSegment 同套路）

/// 底稿来源角色。
public enum BriefRole: String, Codable, Sendable, CaseIterable {
    case agenda
    case priorMinutes = "prior_minutes"
    case proposal
    case roster
    case notes
    case linkedMeeting = "linked_meeting"

    public var displayName: String {
        switch self {
        case .agenda: return "议程"
        case .priorMinutes: return "上场纪要"
        case .proposal: return "议案"
        case .roster: return "名单"
        case .notes: return "备忘"
        case .linkedMeeting: return "关联上场"
        }
    }

    /// 资料列表用 SF Symbol 名（与 RecapUI `RecapSymbol` 对齐；Models 不依赖 UI）。
    public var systemImageName: String {
        switch self {
        case .agenda: return "list.bullet.rectangle"
        case .priorMinutes: return "clock.arrow.circlepath"
        case .proposal: return "doc.richtext"
        case .roster: return "person.3"
        case .notes: return "note.text"
        case .linkedMeeting: return "link"
        }
    }
}

public enum BriefSourceKind: String, Codable, Sendable {
    case scan
    case file
    case paste
    case linkedMeeting
}

public enum BriefParseStatus: String, Codable, Sendable {
    case pending
    case ready
    case failed
}

/// 议程条目（L1 结构层）。
public struct AgendaItem: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var order: Int
    public var title: String
    public var ownerHint: String?
    public var durationHintSeconds: Int?
    /// pending | discussed | decided | skipped
    public var status: String

    public init(id: UUID = UUID(),
                order: Int,
                title: String,
                ownerHint: String? = nil,
                durationHintSeconds: Int? = nil,
                status: String = "pending") {
        self.id = id
        self.order = order
        self.title = title
        self.ownerHint = ownerHint
        self.durationHintSeconds = durationHintSeconds
        self.status = status
    }
}

/// 上场遗留 / 待闭环（L2 连续层）。
public struct OpenItem: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var text: String
    public var ownerHint: String?
    public var dueHint: String?
    public var fromMeetingId: UUID?
    /// open | closed | deferred
    public var resolution: String

    public init(id: UUID = UUID(),
                text: String,
                ownerHint: String? = nil,
                dueHint: String? = nil,
                fromMeetingId: UUID? = nil,
                resolution: String = "open") {
        self.id = id
        self.text = text
        self.ownerHint = ownerHint
        self.dueHint = dueHint
        self.fromMeetingId = fromMeetingId
        self.resolution = resolution
    }
}

/// 一份原始来源（扫描页 / 文件 / 粘贴 / 关联会）。
public struct BriefSource: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var role: BriefRole
    public var kind: BriefSourceKind
    public var title: String
    public var localFilePath: String?
    public var rawText: String?
    public var linkedMeetingId: UUID?
    public var parseStatus: BriefParseStatus
    public var createdAt: Date

    public init(id: UUID = UUID(),
                role: BriefRole,
                kind: BriefSourceKind,
                title: String,
                localFilePath: String? = nil,
                rawText: String? = nil,
                linkedMeetingId: UUID? = nil,
                parseStatus: BriefParseStatus = .ready,
                createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.kind = kind
        self.title = title
        self.localFilePath = localFilePath
        self.rawText = rawText
        self.linkedMeetingId = linkedMeetingId
        self.parseStatus = parseStatus
        self.createdAt = createdAt
    }
}

/// 启发式 / 关联会解析结果。
public struct BriefParseResult: Sendable {
    public var agenda: [AgendaItem]
    public var openItems: [OpenItem]
    public var entityHints: [String]
    public var suggestedTitle: String?

    public init(agenda: [AgendaItem] = [],
                openItems: [OpenItem] = [],
                entityHints: [String] = [],
                suggestedTitle: String? = nil) {
        self.agenda = agenda
        self.openItems = openItems
        self.entityHints = entityHints
        self.suggestedTitle = suggestedTitle
    }

    public var isEmpty: Bool { agenda.isEmpty && openItems.isEmpty }
}

// MARK: - SwiftData 聚合

/// 会前底稿：挂在 Meeting 上的薄层上下文包（一场一会一份）。
@Model
public final class MeetingBrief {
    @Attribute(.unique) public var id: UUID
    public var sourcesData: Data
    public var agendaData: Data
    public var openItemsData: Data
    public var entityHintsData: Data
    public var summaryForPrompt: String
    public var suggestedTitle: String?
    public var updatedAt: Date
    public var meeting: Meeting?

    @Transient private var sourcesCache: [BriefSource]?
    @Transient private var agendaCache: [AgendaItem]?
    @Transient private var openItemsCache: [OpenItem]?
    @Transient private var entityHintsCache: [String]?

    public init(id: UUID = UUID(),
                sources: [BriefSource] = [],
                agenda: [AgendaItem] = [],
                openItems: [OpenItem] = [],
                entityHints: [String] = [],
                summaryForPrompt: String = "",
                suggestedTitle: String? = nil,
                meeting: Meeting? = nil) {
        self.id = id
        self.sourcesData = (try? JSONEncoder().encode(sources)) ?? Data()
        self.agendaData = (try? JSONEncoder().encode(agenda)) ?? Data()
        self.openItemsData = (try? JSONEncoder().encode(openItems)) ?? Data()
        self.entityHintsData = (try? JSONEncoder().encode(entityHints)) ?? Data()
        self.summaryForPrompt = summaryForPrompt
        self.suggestedTitle = suggestedTitle
        self.updatedAt = Date()
        self.meeting = meeting
        self.sourcesCache = sources
        self.agendaCache = agenda
        self.openItemsCache = openItems
        self.entityHintsCache = entityHints
    }

    public var sources: [BriefSource] {
        get {
            if let sourcesCache { return sourcesCache }
            let decoded = (try? JSONDecoder().decode([BriefSource].self, from: sourcesData)) ?? []
            sourcesCache = decoded
            return decoded
        }
        set {
            sourcesData = (try? JSONEncoder().encode(newValue)) ?? Data()
            sourcesCache = newValue
            touch()
        }
    }

    public var agenda: [AgendaItem] {
        get {
            if let agendaCache { return agendaCache }
            let decoded = (try? JSONDecoder().decode([AgendaItem].self, from: agendaData)) ?? []
            agendaCache = decoded
            return decoded
        }
        set {
            agendaData = (try? JSONEncoder().encode(newValue)) ?? Data()
            agendaCache = newValue
            touch()
        }
    }

    public var openItems: [OpenItem] {
        get {
            if let openItemsCache { return openItemsCache }
            let decoded = (try? JSONDecoder().decode([OpenItem].self, from: openItemsData)) ?? []
            openItemsCache = decoded
            return decoded
        }
        set {
            openItemsData = (try? JSONEncoder().encode(newValue)) ?? Data()
            openItemsCache = newValue
            touch()
        }
    }

    public var entityHints: [String] {
        get {
            if let entityHintsCache { return entityHintsCache }
            let decoded = (try? JSONDecoder().decode([String].self, from: entityHintsData)) ?? []
            entityHintsCache = decoded
            return decoded
        }
        set {
            entityHintsData = (try? JSONEncoder().encode(newValue)) ?? Data()
            entityHintsCache = newValue
            touch()
        }
    }

    public var isEmpty: Bool {
        agenda.isEmpty && openItems.isEmpty && sources.isEmpty
    }

    /// Sheet / 无障碍一行状态文案。
    public var chipLabel: String {
        if isEmpty { return "底稿·未添加" }
        var parts: [String] = []
        if !agenda.isEmpty { parts.append("议程\(agenda.count)项") }
        if !openItems.isEmpty { parts.append("遗留\(openItems.count)") }
        if parts.isEmpty { parts.append("已添加") }
        return "底稿·\(parts.joined(separator: "·"))"
    }

    /// 根据当前 agenda / openItems 重算稳定注入摘要。
    public func rebuildPromptSummary() {
        summaryForPrompt = BriefPromptBuilder.build(
            agenda: agenda,
            openItems: openItems,
            entityHints: entityHints
        )
        touch()
    }

    public func touch() {
        updatedAt = Date()
    }

    /// 合并解析结果（追加议程/遗留，去重标题）。
    public func merge(parse: BriefParseResult, source: BriefSource) {
        var nextSources = sources
        nextSources.append(source)
        sources = nextSources

        if agenda.isEmpty {
            agenda = parse.agenda
        } else if !parse.agenda.isEmpty {
            var merged = agenda
            let existingTitles = Set(merged.map { $0.title.lowercased() })
            var order = (merged.map(\.order).max() ?? 0) + 1
            for item in parse.agenda where !existingTitles.contains(item.title.lowercased()) {
                var copy = item
                copy.order = order
                order += 1
                merged.append(copy)
            }
            agenda = merged
        }

        if !parse.openItems.isEmpty {
            var merged = openItems
            let existing = Set(merged.map { $0.text.lowercased() })
            for item in parse.openItems where !existing.contains(item.text.lowercased()) {
                merged.append(item)
            }
            openItems = merged
        }

        if !parse.entityHints.isEmpty {
            var hints = entityHints
            for h in parse.entityHints where !hints.contains(h) {
                hints.append(h)
            }
            entityHints = Array(hints.prefix(40))
        }

        if let title = parse.suggestedTitle, suggestedTitle == nil || suggestedTitle?.isEmpty == true {
            suggestedTitle = title
        }

        rebuildPromptSummary()
    }

    public func clearAll() {
        sources = []
        agenda = []
        openItems = []
        entityHints = []
        summaryForPrompt = ""
        suggestedTitle = nil
        touch()
    }
}

// MARK: - Prompt builder（纯函数，无 LLM）

public enum BriefPromptBuilder {
    /// 生成注入 MinutesPipeline / Ask 的稳定前缀。空底稿返回空串。
    public static func build(agenda: [AgendaItem],
                             openItems: [OpenItem],
                             entityHints: [String] = []) -> String {
        guard !agenda.isEmpty || !openItems.isEmpty else { return "" }

        var lines: [String] = [
            "## 会前底稿（结构层，勿编造未讨论内容）",
        ]

        if !agenda.isEmpty {
            lines.append("### 议程骨架")
            for item in agenda.sorted(by: { $0.order < $1.order }) {
                var row = "\(item.order). \(item.title)"
                if let owner = item.ownerHint, !owner.isEmpty {
                    row += "（\(owner)）"
                }
                lines.append(row)
            }
            lines.append("")
        }

        let open = openItems.filter { $0.resolution == "open" }
        if !open.isEmpty {
            lines.append("### 待闭环（请逐项标注 closed / open / deferred）")
            for item in open {
                var row = "- [ ] \(item.text)"
                if let owner = item.ownerHint, !owner.isEmpty {
                    row += " — \(owner)"
                }
                lines.append(row)
            }
            lines.append("")
        }

        if !entityHints.isEmpty {
            lines.append("### 专有名词提示")
            lines.append(entityHints.prefix(24).joined(separator: "、"))
            lines.append("")
        }

        lines.append("""
        ### 使用规则
        - 议题纪要按议程骨架组织；某议题未出现在转写中 → 标「本场未讨论」，禁止虚构决议
        - 待办优先闭环「待闭环」列表，再提取新待办
        - 数字/专有名词以转写为准；与材料冲突时注明「材料记载 / 口头更正」
        """)

        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
