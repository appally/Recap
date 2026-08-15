import Foundation
import RecapModels

/// 会后卷宗压缩：纪要 / 待办 → 可嵌入 Ask user 的短文本。
public enum AskMeetingDossier {
    public static let maxMinutesChars = 1_800
    public static let maxActionLines = 12

    public struct ActionItemCompact: Sendable, Hashable {
        public var task: String
        public var owner: String?
        public var dueText: String?
        public var status: ActionStatus

        public init(task: String, owner: String? = nil, dueText: String? = nil, status: ActionStatus) {
            self.task = task
            self.owner = owner
            self.dueText = dueText
            self.status = status
        }
    }

    /// 返回可直接嵌入 user 的 Markdown；无内容则 nil。
    public static func minutesBlock(summary: MeetingSummary?) -> String? {
        guard let summary else { return nil }
        var parts: [String] = []

        let tldr = String(summary.tldr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        if !tldr.isEmpty {
            parts.append("## 核心摘要\n\(tldr)")
        }

        let topics = summary.topics.prefix(5)
        if !topics.isEmpty {
            var topicLines: [String] = ["## 议题"]
            for topic in topics {
                let title = String(topic.title.prefix(40))
                topicLines.append("### \(title)")
                for bullet in topic.bullets.prefix(2) {
                    let b = String(bullet.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                    if !b.isEmpty { topicLines.append("- \(b)") }
                }
            }
            parts.append(topicLines.joined(separator: "\n"))
        }

        let decisions = summary.decisions
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
            .filter { !$0.isEmpty }
            .prefix(5)
        if !decisions.isEmpty {
            parts.append("## 决策\n" + decisions.map { "- \($0)" }.joined(separator: "\n"))
        }

        let opens = summary.openQuestions
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
            .filter { !$0.isEmpty }
            .prefix(5)
        if !opens.isEmpty {
            parts.append("## 遗留\n" + opens.map { "- \($0)" }.joined(separator: "\n"))
        }

        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: "\n\n")
        return String(joined.prefix(maxMinutesChars))
    }

    public static func actionItemsBlock(items: [ActionItemCompact]) -> String? {
        let cleaned = items
            .map { item -> ActionItemCompact in
                var copy = item
                copy.task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
                return copy
            }
            .filter { !$0.task.isEmpty }

        guard !cleaned.isEmpty else { return nil }

        let prioritized = cleaned.sorted { a, b in
            priorityRank(a.status) < priorityRank(b.status)
        }
        let lines = prioritized.prefix(maxActionLines).map { item in
            let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
            let ownerLabel = (owner?.isEmpty == false) ? owner! : "待确认"
            let due = item.dueText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let dueLabel = (due?.isEmpty == false) ? due! : "无截止"
            return "- [\(item.status.rawValue)] \(item.task) · \(ownerLabel) · \(dueLabel)"
        }
        return lines.joined(separator: "\n")
    }

    private static func priorityRank(_ status: ActionStatus) -> Int {
        switch status {
        case .draft: return 0
        case .confirmed: return 1
        case .dispatched: return 2
        case .done: return 3
        }
    }
}

/// Ask 按会议阶段选模型（会中 quick / 会后 deep）。
/// 与 Agent 传输层同源：云档（Pro/免费）走网关下发的 `cred.llmModel`，
/// 仅 BYOK DeepSeek 区分 flash/pro——此前无条件返回 DeepSeek 名，云档会打到
/// dashscope 端点直接 400（Ask 降级兜底整体不可用）。
public enum AskModelRouter {
    public static func model(for phase: MeetingPhase) -> String {
        let role: AgentModelRole = (phase == .review) ? .deep : .quick
        return AgentTransportFactory.modelName(for: LLMSelection.selectedTemplate, role: role)
    }
}
