import Foundation

/// Chat Completions 请求编码 / 流式 delta 解码（纯函数，可离线测）。
///
/// DeepSeek V4 thinking 核心规则：含 tool call 的 assistant 轮必须回传 `reasoning_content`。
public enum ChatCompletionsCodec {

    // MARK: - Request

    public static func encodeRequestBody(
        messages: [AgentMessage],
        tools: [AgentToolSpec],
        options: AgentTransportOptions,
        capabilities: AgentTransportCapabilities
    ) throws -> Data {
        var root: [String: Any] = [
            "model": options.model,
            "temperature": options.temperature,
            "stream": true,
        ]

        root["messages"] = try messages.map { message -> [String: Any] in
            try encodeMessage(message, capabilities: capabilities)
        }

        if options.allowTools, !tools.isEmpty {
            root["tools"] = try tools.map { try encodeTool($0) }
            // 恒为 auto；永不写 required / any / 函数 dict。
            root["tool_choice"] = "auto"
        }

        switch options.thinking {
        case .providerDefault:
            break
        case .enabled:
            root["thinking"] = ["type": "enabled"]
        case .disabled:
            root["thinking"] = ["type": "disabled"]
        }

        return try JSONSerialization.data(withJSONObject: root)
    }

    /// 降级重试前：给含 tool call 但缺 reasoning 的 assistant 补空串，避免二次 400。
    public static func withReasoningRoundTripFilled(_ messages: [AgentMessage]) -> [AgentMessage] {
        messages.map { msg in
            guard case .assistant(let turn) = msg,
                  turn.requestsTools,
                  turn.reasoningContent == nil
            else { return msg }
            return .assistant(AgentAssistantTurn(
                content: turn.content,
                reasoningContent: "",
                toolCalls: turn.toolCalls
            ))
        }
    }

    private static func encodeMessage(
        _ message: AgentMessage,
        capabilities: AgentTransportCapabilities
    ) throws -> [String: Any] {
        switch message {
        case .system(let text):
            return ["role": "system", "content": text]
        case .user(let text):
            return ["role": "user", "content": text]
        case .assistant(let turn):
            var dict: [String: Any] = [
                "role": "assistant",
                "content": turn.content ?? "",
            ]
            if !turn.toolCalls.isEmpty {
                dict["tool_calls"] = turn.toolCalls.map { call -> [String: Any] in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.argumentsJSON,
                        ] as [String: Any],
                    ]
                }
                // DeepSeek thinking：含 tool call 时必须带 reasoning_content 键（缺则用空串）。
                if capabilities.requiresReasoningRoundTrip {
                    dict["reasoning_content"] = turn.reasoningContent ?? ""
                }
            }
            return dict
        case .tool(let callId, _, let content):
            // name 不发送；DeepSeek/OpenAI 均以 tool_call_id 关联。
            return [
                "role": "tool",
                "tool_call_id": callId,
                "content": content,
            ]
        }
    }

    private static func encodeTool(_ spec: AgentToolSpec) throws -> [String: Any] {
        guard let data = spec.parametersJSON.data(using: .utf8),
              let parameters = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AgentTransportError.malformedStream("工具 \(spec.name) 的 parametersJSON 非法")
        }
        return [
            "type": "function",
            "function": [
                "name": spec.name,
                "description": spec.description,
                "parameters": parameters,
            ] as [String: Any],
        ]
    }

    // MARK: - Delta

    public struct ToolCallDelta: Sendable, Equatable {
        public let index: Int
        public let id: String?
        public let name: String?
        public let argumentsChunk: String?

        public init(index: Int, id: String? = nil, name: String? = nil, argumentsChunk: String? = nil) {
            self.index = index
            self.id = id
            self.name = name
            self.argumentsChunk = argumentsChunk
        }
    }

    public struct DeltaFragment: Sendable, Equatable {
        public var content: String?
        public var reasoningContent: String?
        public var toolCallDeltas: [ToolCallDelta]
        public var finishReason: String?

        public init(
            content: String? = nil,
            reasoningContent: String? = nil,
            toolCallDeltas: [ToolCallDelta] = [],
            finishReason: String? = nil
        ) {
            self.content = content
            self.reasoningContent = reasoningContent
            self.toolCallDeltas = toolCallDeltas
            self.finishReason = finishReason
        }
    }

    public static func decodeDelta(_ json: Data) throws -> DeltaFragment {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first
        else {
            throw AgentTransportError.malformedStream("缺少 choices")
        }

        let finishReason = first["finish_reason"] as? String
        let delta = first["delta"] as? [String: Any] ?? [:]

        let content = delta["content"] as? String
        let reasoning =
            (delta["reasoning_content"] as? String)
            ?? (delta["reasoning"] as? String)

        var toolDeltas: [ToolCallDelta] = []
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            for call in calls {
                let index = call["index"] as? Int ?? 0
                let id = call["id"] as? String
                let function = call["function"] as? [String: Any]
                let name = function?["name"] as? String
                let args = function?["arguments"] as? String
                toolDeltas.append(ToolCallDelta(
                    index: index,
                    id: id,
                    name: name,
                    argumentsChunk: args
                ))
            }
        }

        return DeltaFragment(
            content: content,
            reasoningContent: reasoning,
            toolCallDeltas: toolDeltas,
            finishReason: finishReason
        )
    }

    // MARK: - Accumulator

    /// 流式 tool_calls 按 `index` 增量拼接。
    public struct ToolCallAccumulator: Sendable {
        private struct Slot {
            var id: String = ""
            var name: String = ""
            var arguments: String = ""
        }

        private var slots: [Int: Slot] = [:]

        public init() {}

        public mutating func ingest(_ deltas: [ToolCallDelta]) {
            for delta in deltas {
                var slot = slots[delta.index] ?? Slot()
                if let id = delta.id, !id.isEmpty { slot.id = id }
                if let name = delta.name, !name.isEmpty { slot.name = name }
                if let chunk = delta.argumentsChunk { slot.arguments += chunk }
                slots[delta.index] = slot
            }
        }

        /// 按 index 升序；丢弃 name 为空的项。
        public func finish() -> [AgentToolCall] {
            slots.keys.sorted().compactMap { index in
                guard let slot = slots[index], !slot.name.isEmpty else { return nil }
                let id = slot.id.isEmpty ? "call_\(index)" : slot.id
                return AgentToolCall(
                    id: id,
                    name: slot.name,
                    argumentsJSON: slot.arguments.isEmpty ? "{}" : slot.arguments
                )
            }
        }
    }
}
