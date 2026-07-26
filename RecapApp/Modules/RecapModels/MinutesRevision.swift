import Foundation

/// 改写产出：整份新纪要（模型重写受影响字段，未提及字段回填原值）。
public struct MinutesRevisionPayload: Sendable, Codable, Equatable {
    public let tldr: String?
    public let topics: [MeetingTopic]?
    public let decisions: [String]?
    public let openQuestions: [String]?
    /// 模型对每处改动的一句说明 + 是否有转写依据。
    public let changeNotes: [ChangeNote]

    public struct ChangeNote: Sendable, Codable, Hashable {
        public let field: String
        public let note: String
        public let hasTranscriptEvidence: Bool

        public init(field: String, note: String, hasTranscriptEvidence: Bool) {
            self.field = field
            self.note = note
            self.hasTranscriptEvidence = hasTranscriptEvidence
        }

        enum CodingKeys: String, CodingKey {
            case field, note
            case hasTranscriptEvidence = "has_transcript_evidence"
        }
    }

    public init(
        tldr: String? = nil,
        topics: [MeetingTopic]? = nil,
        decisions: [String]? = nil,
        openQuestions: [String]? = nil,
        changeNotes: [ChangeNote] = []
    ) {
        self.tldr = tldr
        self.topics = topics
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.changeNotes = changeNotes
    }

    enum CodingKeys: String, CodingKey {
        case tldr, topics, decisions
        case openQuestions = "open_questions"
        case changeNotes = "change_notes"
    }
}

public enum MinutesDiff {
    public struct FieldDiff: Sendable, Hashable, Identifiable {
        public var id: String { field }
        public let field: String
        public let before: [String]
        public let after: [String]
        public let changed: Bool
        public let evidenceBacked: Bool
        public let note: String?

        public init(
            field: String,
            before: [String],
            after: [String],
            changed: Bool,
            evidenceBacked: Bool,
            note: String? = nil
        ) {
            self.field = field
            self.before = before
            self.after = after
            self.changed = changed
            self.evidenceBacked = evidenceBacked
            self.note = note
        }

        public var displayName: String {
            switch field {
            case "tldr": return "核心摘要"
            case "topics": return "议题纪要"
            case "decisions": return "决策"
            case "openQuestions": return "遗留问题"
            default: return field
            }
        }
    }

    /// nil 字段视为「不改」，回填原值。
    public static func apply(_ payload: MinutesRevisionPayload, to base: MeetingSummary) -> MeetingSummary {
        MeetingSummary(
            tldr: payload.tldr ?? base.tldr,
            topics: payload.topics ?? base.topics,
            decisions: payload.decisions ?? base.decisions,
            openQuestions: payload.openQuestions ?? base.openQuestions
        )
    }

    /// 仅应用勾选字段；未勾选的保持 base。
    public static func apply(
        _ payload: MinutesRevisionPayload,
        to base: MeetingSummary,
        selectedFields: Set<String>
    ) -> MeetingSummary {
        MeetingSummary(
            tldr: selectedFields.contains("tldr") ? (payload.tldr ?? base.tldr) : base.tldr,
            topics: selectedFields.contains("topics") ? (payload.topics ?? base.topics) : base.topics,
            decisions: selectedFields.contains("decisions") ? (payload.decisions ?? base.decisions) : base.decisions,
            openQuestions: selectedFields.contains("openQuestions")
                ? (payload.openQuestions ?? base.openQuestions)
                : base.openQuestions
        )
    }

    public static func compute(
        base: MeetingSummary,
        revised: MeetingSummary,
        notes: [MinutesRevisionPayload.ChangeNote]
    ) -> [FieldDiff] {
        func note(for field: String) -> MinutesRevisionPayload.ChangeNote? {
            notes.first { $0.field == field || $0.field == snake(field) }
        }
        func snake(_ field: String) -> String {
            switch field {
            case "openQuestions": return "open_questions"
            default: return field
            }
        }

        let fields: [(String, [String], [String])] = [
            ("tldr", [base.tldr], [revised.tldr]),
            ("topics", topicLines(base.topics), topicLines(revised.topics)),
            ("decisions", base.decisions, revised.decisions),
            ("openQuestions", base.openQuestions, revised.openQuestions),
        ]

        return fields.map { field, before, after in
            let changed = before != after
            let n = note(for: field)
            // 无 note 时：有改动默认视为有依据（保守勾选）；有 note 则听模型
            let backed: Bool
            if let n {
                backed = n.hasTranscriptEvidence
            } else {
                backed = true
            }
            return FieldDiff(
                field: field,
                before: before,
                after: after,
                changed: changed,
                evidenceBacked: backed,
                note: n?.note
            )
        }
    }

    private static func topicLines(_ topics: [MeetingTopic]) -> [String] {
        topics.map { topic in
            let bullets = topic.bullets.joined(separator: "；")
            return bullets.isEmpty ? topic.title : "\(topic.title)：\(bullets)"
        }
    }
}
