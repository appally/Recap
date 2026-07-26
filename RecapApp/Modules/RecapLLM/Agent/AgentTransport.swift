import Foundation

public enum AgentThinkingMode: Sendable, Equatable {
    case providerDefault
    case enabled
    case disabled
}

public struct AgentTransportOptions: Sendable {
    public var model: String
    public var temperature: Double
    public var thinking: AgentThinkingMode
    /// 恒为 auto/none。**不提供强制某个函数的入口**（DeepSeek thinking 会 400）。
    public var allowTools: Bool
    public var timeout: TimeInterval

    public init(
        model: String,
        temperature: Double = 0.2,
        thinking: AgentThinkingMode = .providerDefault,
        allowTools: Bool = true,
        timeout: TimeInterval = 120
    ) {
        self.model = model
        self.temperature = temperature
        self.thinking = thinking
        self.allowTools = allowTools
        self.timeout = timeout
    }
}

public enum AgentTransportEvent: Sendable {
    case reasoningDelta(String)
    case textDelta(String)
    /// 本轮结束。含 toolCalls 时调用方须执行工具并把本 turn 原样放回 messages。
    case turnFinished(AgentAssistantTurn)
}

public struct AgentTransportCapabilities: Sendable, Equatable {
    public let supportsTools: Bool
    /// true → 含 tool call 的轮次必须回传 reasoning_content（DeepSeek V4）
    public let requiresReasoningRoundTrip: Bool
    public let supportsThinkingToggle: Bool

    public init(
        supportsTools: Bool,
        requiresReasoningRoundTrip: Bool,
        supportsThinkingToggle: Bool
    ) {
        self.supportsTools = supportsTools
        self.requiresReasoningRoundTrip = requiresReasoningRoundTrip
        self.supportsThinkingToggle = supportsThinkingToggle
    }
}

public protocol AgentTransport: Sendable {
    var id: String { get }
    var capabilities: AgentTransportCapabilities { get }
    func stream(
        messages: [AgentMessage],
        tools: [AgentToolSpec],
        options: AgentTransportOptions
    ) -> AsyncThrowingStream<AgentTransportEvent, Error>
}

public enum AgentTransportError: Error, LocalizedError, Sendable, Equatable {
    case http(status: Int, body: String)
    /// 400 且 body 含 tool_choice 相关拒绝。
    case toolChoiceRejected(String)
    /// 400 且 body 含 reasoning_content 必须回传。
    case reasoningRoundTripRequired(String)
    case malformedStream(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            let snippet = body.prefix(240)
            return "Agent 传输 HTTP \(status)：\(snippet)"
        case .toolChoiceRejected(let body):
            return "tool_choice 被拒：\(body.prefix(240))"
        case .reasoningRoundTripRequired(let body):
            return "需回传 reasoning_content：\(body.prefix(240))"
        case .malformedStream(let msg):
            return "流式解析失败：\(msg)"
        }
    }

    /// 把 HTTP 状态与 body 分类为可降级错误（纯函数，可离线测）。
    public static func classify(status: Int, body: String) -> AgentTransportError {
        guard status == 400 else {
            return .http(status: status, body: body)
        }
        let lower = body.lowercased()
        if lower.contains("tool_choice") || body.contains("does not support this tool choice")
            || body.contains("does not support this tool_choice")
        {
            return .toolChoiceRejected(body)
        }
        if lower.contains("reasoning_content") {
            return .reasoningRoundTripRequired(body)
        }
        return .http(status: status, body: body)
    }

    /// 降级只允许发生一次：`attempt == 0` 且错误可降级时返回 true。
    public static func shouldDowngrade(attempt: Int, error: AgentTransportError) -> Bool {
        guard attempt == 0 else { return false }
        switch error {
        case .toolChoiceRejected, .reasoningRoundTripRequired:
            return true
        case .http, .malformedStream:
            return false
        }
    }

    /// 429 / 5xx 有限重试（最多额外 2 次）。
    public static func shouldRetryTransient(attempt: Int, error: AgentTransportError) -> Bool {
        guard attempt < 2 else { return false }
        switch error {
        case .http(let status, _) where status == 429 || (500...599).contains(status):
            return true
        case .http, .toolChoiceRejected, .reasoningRoundTripRequired, .malformedStream:
            return false
        }
    }
}
