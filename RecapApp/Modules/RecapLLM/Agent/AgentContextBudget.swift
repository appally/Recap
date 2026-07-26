import Foundation

/// 上下文预算裁剪（纯函数）。
///
/// `compact` **替换而非删除** `.tool` 消息——删掉会破坏 `tool_call_id` 配对导致 400。
public enum AgentContextBudget {
    public static let truncationSuffix = "…（结果已截断）"
    public static let omittedPlaceholder = "…（早前工具结果已省略）"

    /// 单个工具结果裁剪；被截断时结尾附提示让模型知情。
    public static func clipToolResult(_ text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return truncationSuffix }
        let trimmed = text
        guard trimmed.count > maxChars else { return trimmed }
        let keep = max(0, maxChars - truncationSuffix.count)
        return String(trimmed.prefix(keep)) + truncationSuffix
    }

    /// 累计超限时，从最旧的 tool 消息开始替换为占位；**条数与 callId 集合不变**。
    public static func compact(_ messages: [AgentMessage], maxTotalToolChars: Int) -> [AgentMessage] {
        let toolIndices = messages.indices.filter {
            if case .tool = messages[$0] { return true }
            return false
        }
        guard !toolIndices.isEmpty else { return messages }

        func totalToolChars(_ msgs: [AgentMessage]) -> Int {
            msgs.reduce(0) { acc, msg in
                if case .tool(_, _, let content) = msg {
                    return acc + content.count
                }
                return acc
            }
        }

        var result = messages
        var total = totalToolChars(result)
        guard total > maxTotalToolChars else { return result }

        for index in toolIndices {
            guard total > maxTotalToolChars else { break }
            guard case .tool(let callId, let name, let content) = result[index] else { continue }
            if content == omittedPlaceholder { continue }
            total -= content.count
            result[index] = .tool(callId: callId, name: name, content: omittedPlaceholder)
            total += omittedPlaceholder.count
        }
        return result
    }

    /// 去掉较早 assistant 轮次的 `reasoningContent`，只保留最近一轮含 tool call 的思考链，控制上下文膨胀。
    public static func stripStaleReasoning(_ messages: [AgentMessage]) -> [AgentMessage] {
        var lastToolAssistantIndex: Int?
        for (idx, msg) in messages.enumerated() {
            if case .assistant(let turn) = msg, turn.requestsTools {
                lastToolAssistantIndex = idx
            }
        }
        guard let keep = lastToolAssistantIndex else {
            return messages.map { msg in
                guard case .assistant(let turn) = msg,
                      turn.reasoningContent != nil,
                      !turn.requestsTools
                else { return msg }
                return .assistant(AgentAssistantTurn(
                    content: turn.content,
                    reasoningContent: nil,
                    toolCalls: turn.toolCalls
                ))
            }
        }
        return messages.enumerated().map { idx, msg in
            guard case .assistant(let turn) = msg,
                  turn.reasoningContent != nil,
                  idx != keep
            else { return msg }
            return .assistant(AgentAssistantTurn(
                content: turn.content,
                reasoningContent: nil,
                toolCalls: turn.toolCalls
            ))
        }
    }
}
