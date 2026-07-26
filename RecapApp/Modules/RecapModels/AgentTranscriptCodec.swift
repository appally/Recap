import Foundation

/// Ask 会话落库编解码。
///
/// 恢复历史时**只含短问短答文本，不含工具消息**：
/// - `.tool` 必须与同请求内 `tool_call_id` 配对，跨会话重放极易 400
/// - 工具结果易失（网页会变、转写会增长），重放旧结果有害
/// - 与 `AskHistoryBudget` 语义一致（只留短问短答）
public enum AgentTranscriptCodec {
    public static let maxRetainedSteps = 60

    public static func encodeCitations(_ snapshots: [AskCitationSnapshot]) -> Data? {
        guard !snapshots.isEmpty else { return nil }
        return try? JSONEncoder().encode(snapshots)
    }

    public static func decodeCitations(_ data: Data?) -> [AskCitationSnapshot] {
        guard let data, !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([AskCitationSnapshot].self, from: data)) ?? []
    }

    /// 超出上限时返回应删除的最旧步骤（按 `startedAt`）。
    public static func stepsToPrune(_ steps: [AgentStepRecord]) -> [AgentStepRecord] {
        guard steps.count > maxRetainedSteps else { return [] }
        let sorted = steps.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.index < rhs.index
        }
        let excess = steps.count - maxRetainedSteps
        return Array(sorted.prefix(excess))
    }
}
