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
        // produced 守卫：已向下游 yield 任意可见 delta 后**绝不重试**（重试会从头再产出，
        // AgentKernel 累加 streamedText 致 UI 重复/乱序）。inout 传入，抛错时也能反映已产出量。
        var produced = false
        do {
            try await performOnce(
                apiKey: apiKey,
                baseURL: baseURL,
                capabilities: capabilities,
                messages: messages,
                tools: tools,
                options: options,
                produced: &produced,
                continuation: continuation
            )
        } catch let error as AgentTransportError {
            if !produced,
               AgentTransportError.shouldDowngrade(attempt: attempt, error: error),
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
            if !produced, AgentTransportError.shouldRetryTransient(attempt: attempt, error: error) {
                // M8：try? -> try，让取消在 sleep 阶段即抛出终止重试（否则吞 CancellationError 后仍发新请求）。
                let delayNs = UInt64(300_000_000) * UInt64(attempt + 1)
                try await Task.sleep(nanoseconds: delayNs)
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
            if attempt < 2, !produced {
                // M8：try? -> try，取消在 sleep 即生效，不再多发一次请求。
                let delayNs = UInt64(300_000_000) * UInt64(attempt + 1)
                try await Task.sleep(nanoseconds: delayNs)
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
        produced: inout Bool,
        continuation: AsyncThrowingStream<AgentTransportEvent, Error>.Continuation
    ) async throws {
        let body = try ChatCompletionsCodec.encodeRequestBody(
            messages: messages,
            tools: tools,
            options: options,
            capabilities: capabilities
        )

        var request = URLRequest(url: try chatCompletionsURL(from: baseURL))
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

        var reasoning = ""
        var accumulator = ChatCompletionsCodec.ToolCallAccumulator()
        var sawFinish = false
        var dsmlFilter = DeepSeekDSML.StreamFilter()

        // 按行消费（此前逐字节迭代 + 手工拼缓冲：每字节一次挂起/恢复，长回答放大开销；
        // SSE 是行协议，CRLF/LF 由 lines 归一，余下交给 SSELineParser）。
        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            if try handleSSELine(
                line,
                reasoning: &reasoning,
                accumulator: &accumulator,
                sawFinish: &sawFinish,
                dsmlFilter: &dsmlFilter,
                continuation: continuation
            ) { produced = true }
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
    ) throws -> Bool {
        switch SSELineParser.classify(line) {
        case .ignorable:
            return false
        case .done:
            sawFinish = true
            return false
        case .data(let payload):
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
            let fragment = try ChatCompletionsCodec.decodeDelta(data)
            var yielded = false
            if let r = fragment.reasoningContent, !r.isEmpty {
                reasoning += r
                continuation.yield(.reasoningDelta(r))
                yielded = true
            }
            if !fragment.toolCallDeltas.isEmpty {
                accumulator.ingest(fragment.toolCallDeltas)
                dsmlFilter.noteStructuredToolCalls()
            }
            if let c = fragment.content, !c.isEmpty {
                let visible = dsmlFilter.ingest(c)
                if !visible.isEmpty {
                    continuation.yield(.textDelta(visible))
                    yielded = true
                }
            }
            if fragment.finishReason != nil {
                sawFinish = true
            }
            return yielded
        }
    }

    static func chatCompletionsURL(from baseURL: String) throws -> URL {
        let trimmed = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let withScheme: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }
        // BYOK baseURL 含空格/非 ASCII 等非法字符时 URL 构造失败；旧版强解会崩，改为抛 badURL。
        guard let url = URL(string: "\(withScheme)/chat/completions") else {
            throw URLError(.badURL)
        }
        return url
    }
}
