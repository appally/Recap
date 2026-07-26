import Foundation

/// Ask 多轮对话角色（进入 ChatQuery 的历史轮次）。
public enum AskChatRole: String, Sendable, Hashable {
    case user
    case assistant
}

/// 一条已完成的对话轮次（短问 / 短答；不含检索证据块）。
public struct AskChatTurn: Sendable, Hashable {
    public let role: AskChatRole
    public let content: String

    public init(role: AskChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// 历史截断：最近优先、字符预算、避免以 orphan assistant 开头。
public enum AskHistoryBudget {
    public static let maxTurns = 6
    public static let maxTotalChars = 4_000

    /// 只保留已完成轮次；从最新往旧截到预算内。
    public static func trim(_ turns: [AskChatTurn]) -> [AskChatTurn] {
        let cleaned = turns.compactMap { turn -> AskChatTurn? in
            let text = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return AskChatTurn(role: turn.role, content: text)
        }
        guard !cleaned.isEmpty else { return [] }

        var keptRev: [AskChatTurn] = []
        var totalChars = 0
        for turn in cleaned.reversed() {
            if keptRev.count >= maxTurns { break }
            let next = totalChars + turn.content.count
            if !keptRev.isEmpty, next > maxTotalChars { break }
            keptRev.append(turn)
            totalChars = next
        }

        var kept = Array(keptRev.reversed())
        while kept.first?.role == .assistant {
            kept.removeFirst()
        }
        return kept
    }
}
