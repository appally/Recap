import Foundation

/// 一次工具调用。`id` 必须与后续 `.tool` 消息的 `tool_call_id` 一致。
public struct AgentToolCall: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// 原始 JSON 字符串（不提前解码，容错更好）。
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// 一次 assistant 轮次的完整产出。
/// 含 tool call 时，`reasoningContent` 在 DeepSeek V4 thinking 模式下必须原样回传。
public struct AgentAssistantTurn: Sendable, Hashable {
    public let content: String?
    public let reasoningContent: String?
    public let toolCalls: [AgentToolCall]

    public init(
        content: String? = nil,
        reasoningContent: String? = nil,
        toolCalls: [AgentToolCall] = []
    ) {
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
    }

    public var requestsTools: Bool { !toolCalls.isEmpty }
}

/// Agent 传输层消息。与 `AskChatTurn` 语义不同，不提供兼容构造（转换在 027）。
public enum AgentMessage: Sendable, Hashable {
    case system(String)
    case user(String)
    case assistant(AgentAssistantTurn)
    case tool(callId: String, name: String, content: String)
}
