import Foundation

/// DeepSeek V4 Agent 传输：`tool_choice: auto` + `reasoning_content` 往返。
public struct DeepSeekAgentTransport: AgentTransport {
    public let id: String
    private let apiKey: String
    private let baseURL: String

    public init(id: String = "deepseek", apiKey: String, baseURL: String = "https://api.deepseek.com") {
        self.id = id
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public var capabilities: AgentTransportCapabilities {
        AgentTransportCapabilities(
            supportsTools: true,
            requiresReasoningRoundTrip: true,
            supportsThinkingToggle: true
        )
    }

    public func stream(
        messages: [AgentMessage],
        tools: [AgentToolSpec],
        options: AgentTransportOptions
    ) -> AsyncThrowingStream<AgentTransportEvent, Error> {
        OpenAICompatibleAgentStreaming.stream(
            apiKey: apiKey,
            baseURL: baseURL,
            capabilities: capabilities,
            messages: messages,
            tools: tools,
            options: options
        )
    }
}

/// 其它 OpenAI 兼容端点（无 reasoning_content 往返要求）。
public struct OpenAIToolTransport: AgentTransport {
    public let id: String
    private let apiKey: String
    private let baseURL: String
    private let toolsSupported: Bool

    public init(
        id: String,
        apiKey: String,
        baseURL: String,
        toolsSupported: Bool = true
    ) {
        self.id = id
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.toolsSupported = toolsSupported
    }

    public var capabilities: AgentTransportCapabilities {
        AgentTransportCapabilities(
            supportsTools: toolsSupported,
            requiresReasoningRoundTrip: false,
            supportsThinkingToggle: false
        )
    }

    public func stream(
        messages: [AgentMessage],
        tools: [AgentToolSpec],
        options: AgentTransportOptions
    ) -> AsyncThrowingStream<AgentTransportEvent, Error> {
        var opts = options
        // 非 DeepSeek：不发 thinking 键
        opts.thinking = .providerDefault
        return OpenAICompatibleAgentStreaming.stream(
            apiKey: apiKey,
            baseURL: baseURL,
            capabilities: capabilities,
            messages: messages,
            tools: toolsSupported ? tools : [],
            options: opts
        )
    }
}

// MARK: - Shared streaming

enum OpenAICompatibleAgentStreaming {
    static func stream(
        apiKey: String,
        baseURL: String,
        capabilities: AgentTransportCapabilities,
        messages: [AgentMessage],
        tools: [AgentToolSpec],
        options: AgentTransportOptions
    ) -> AsyncThrowingStream<AgentTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(
                        apiKey: apiKey,
                        baseURL: baseURL,
                        capabilities: capabilities,
                        messages: messages,
                        tools: tools,
                        options: options,
                        attempt: 0,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        apiKey: String,
        baseURL: String,
        capabilities: AgentTransportCapabilities,
        messages: [AgentMessage],
        tools: [AgentToolSpec],
        options: AgentTransportOptions,
        attempt: Int,
        continuation: AsyncThrowingStream<AgentTransportEvent, Error>.Continuation
    ) async throws {
        do {
            try await performOnce(
                apiKey: apiKey,
                baseURL: baseURL,
                capabilities: capabilities,
                messages: messages,
                tools: tools,
                options: options,
                continuation: continuation
            )
        } catch let error as AgentTransportError {
            if AgentTransportError.shouldDowngrade(attempt: attempt, error: error),
               capabilities.supportsThinkingToggle
            {
                continuation.yield(.reasoningDelta("（已降级为非思考模式）"))
                var downgraded = options
                downgraded.thinking = .disabled
                var retryMessages = messages
                if case .reasoningRoundTripRequired = error {
                    retryMessages = ChatCompletionsCodec.withReasoningRoundTripFilled(messages)
                }
                try await run(
                    apiKey: apiKey,
                    baseURL: baseURL,
                    capabilities: capabilities,
                    messages: retryMessages,
                    tools: tools,
                    options: downgraded,
                    attempt: attempt + 1,
                    continuation: continuation
                )
                return
            }
            if AgentTransportError.shouldRetryTransient(attempt: attempt, error: error) {
                let delayNs = UInt64(300_000_000) * UInt64(attempt + 1)
                try? await Task.sleep(nanoseconds: delayNs)
                try await run(
                    apiKey: apiKey,
                    baseURL: baseURL,
                    capabilities: capabilities,
                    messages: messages,
                    tools: tools,
                    options: options,
                    attempt: attempt + 1,
                    continuation: continuation
                )
                return
            }
            throw error
        } catch let urlError as URLError
            where urlError.code == .timedOut
                || urlError.code == .networkConnectionLost
                || urlError.code == .notConnectedToInternet
        {
            if attempt < 2 {
                let delayNs = UInt64(300_000_000) * UInt64(attempt + 1)
                try? await Task.sleep(nanoseconds: delayNs)
                try await run(
                    apiKey: apiKey,
                    baseURL: baseURL,
                    capabilities: capabilities,
                    messages: messages,
                    tools: tools,
                    options: options,
                    attempt: attempt + 1,
                    continuation: continuation
                )
                return
            }
            throw urlError
        }
    }

    private static func performOnce(
        apiKey: String,
        baseURL: String,
        capabilities: AgentTransportCapabilities,
        messages: [AgentMessage],
        tools: [AgentToolSpec],
        options: AgentTransportOptions,
        continuation: AsyncThrowingStream<AgentTransportEvent, Error>.Continuation
    ) async throws {
        let body = try ChatCompletionsCodec.encodeRequestBody(
            messages: messages,
            tools: tools,
            options: options,
            capabilities: capabilities
        )

        var request = URLRequest(url: chatCompletionsURL(from: baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        request.timeoutInterval = options.timeout

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentTransportError.malformedStream("无 HTTP 响应")
        }

        if !(200..<300).contains(http.statusCode) {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 8_192 { break }
            }
            let bodyText = String(data: errorData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AgentTransportError.classify(status: http.statusCode, body: bodyText)
        }

        var lineBuffer = Data()
        var reasoning = ""
        var accumulator = ChatCompletionsCodec.ToolCallAccumulator()
        var sawFinish = false
        var dsmlFilter = DeepSeekDSML.StreamFilter()

        for try await byte in bytes {
            if Task.isCancelled { throw CancellationError() }
            if byte == UInt8(ascii: "\n") {
                let line = String(data: lineBuffer, encoding: .utf8) ?? ""
                lineBuffer.removeAll(keepingCapacity: true)
                try handleSSELine(
                    line,
                    reasoning: &reasoning,
                    accumulator: &accumulator,
                    sawFinish: &sawFinish,
                    dsmlFilter: &dsmlFilter,
                    continuation: continuation
                )
            } else {
                lineBuffer.append(byte)
            }
        }

        if !lineBuffer.isEmpty {
            let line = String(data: lineBuffer, encoding: .utf8) ?? ""
            try handleSSELine(
                line,
                reasoning: &reasoning,
                accumulator: &accumulator,
                sawFinish: &sawFinish,
                dsmlFilter: &dsmlFilter,
                continuation: continuation
            )
        }

        let structured = accumulator.finish()
        let finalized = dsmlFilter.finish(structuredToolCalls: structured)
        let turn = AgentAssistantTurn(
            content: finalized.content,
            reasoningContent: reasoning.isEmpty ? nil : reasoning,
            toolCalls: finalized.toolCalls
        )
        continuation.yield(.turnFinished(turn))
    }

    private static func handleSSELine(
        _ line: String,
        reasoning: inout String,
        accumulator: inout ChatCompletionsCodec.ToolCallAccumulator,
        sawFinish: inout Bool,
        dsmlFilter: inout DeepSeekDSML.StreamFilter,
        continuation: AsyncThrowingStream<AgentTransportEvent, Error>.Continuation
    ) throws {
        switch SSELineParser.classify(line) {
        case .ignorable:
            return
        case .done:
            sawFinish = true
            return
        case .data(let payload):
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
            let fragment = try ChatCompletionsCodec.decodeDelta(data)
            if let r = fragment.reasoningContent, !r.isEmpty {
                reasoning += r
                continuation.yield(.reasoningDelta(r))
            }
            if !fragment.toolCallDeltas.isEmpty {
                accumulator.ingest(fragment.toolCallDeltas)
                dsmlFilter.noteStructuredToolCalls()
            }
            if let c = fragment.content, !c.isEmpty {
                let visible = dsmlFilter.ingest(c)
                if !visible.isEmpty {
                    continuation.yield(.textDelta(visible))
                }
            }
            if fragment.finishReason != nil {
                sawFinish = true
            }
        }
    }

    static func chatCompletionsURL(from baseURL: String) -> URL {
        let trimmed = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let withScheme: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }
        return URL(string: "\(withScheme)/chat/completions")!
    }
}
