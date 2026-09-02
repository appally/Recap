import Foundation
import OpenAI
import RecapModels

/// MacPaw/OpenAI 兼容实现：接 DeepSeek V4（及任何 OpenAI 兼容端点）。
public final class OpenAICompatibleProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let defaultModel: String
    public let summaryModel: String
    private let client: OpenAI
    private let apiKey: String
    private let host: String
    private let basePath: String
    /// 首 token 超时预算（秒）：产出首个有效 delta 前若超过则放弃本次、按瞬态错误重试。
    /// MacPaw 流式 session 库内部自建 `.default` URLSession、不可注入超时（吃默认 60s），
    /// 故在 provider 内用「首 token race」兜底，避免一场短会卡满 60s 才知道失败。
    private let firstTokenTimeoutSeconds: Double

    /// - Parameter baseURL: 完整 OpenAI 兼容基址（含路径，如
    ///   `https://dashscope.aliyuncs.com/compatible-mode/v1`）。自动拆 host + basePath；
    ///   MacPaw 与原始 HTTP 都走全路径，修子路径被吞（旧实现在此丢 qwen/glm/doubao/gemini/claude 的路径）。
    /// - Parameter summaryModel: 纪要等高质量任务用的强模型；nil 时与 defaultModel 同款。
    /// - Parameter firstTokenTimeoutSeconds: 首 token 超时；命中后按瞬态错误重试（与 QUIC 抖动同路）。
    public init(id: String = "deepseek",
                apiKey: String,
                baseURL: String = "https://api.deepseek.com",
                defaultModel: String = LLMPresets.deepSeekFlash,
                summaryModel: String? = nil,
                firstTokenTimeoutSeconds: Double = 20) {
        self.id = id
        self.defaultModel = defaultModel
        self.summaryModel = summaryModel ?? defaultModel
        self.apiKey = apiKey
        let parsed = Self.parseBaseURL(baseURL)
        self.host = parsed.host
        self.basePath = parsed.basePath
        self.firstTokenTimeoutSeconds = firstTokenTimeoutSeconds
        self.client = OpenAI(configuration: .init(token: apiKey, host: parsed.host, basePath: parsed.basePath))
    }

    /// `https://a.com/compatible-mode/v1` -> ("a.com", "/compatible-mode/v1")；无路径默认 "/v1"。
    static func parseBaseURL(_ baseURL: String) -> (host: String, basePath: String) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let h = url.host, !h.isEmpty else {
            return (trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "/v1")
        }
        var path = url.path
        if path.isEmpty { path = "/v1" }
        if !path.hasPrefix("/") { path = "/" + path }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "/v1" }
        return (h, path)
    }

    // MARK: - Streaming（瞬态重试 + 首 token 超时）

    /// 首 token 超时（不跨模块，避免 RecapLLM 依赖 RecapASR 的 InferenceTimeoutError）。
    private struct FirstTokenTimeoutError: Error, LocalizedError {
        let seconds: Double
        var errorDescription: String? { "首 token 超时（\(Int(seconds))s 内无响应）" }
    }

    /// 瞬态重试上限：`attempt < maxRetries` ⇒ 共 maxRetries+1 次尝试。
    /// 退避策略抄 ``OpenAICompatibleAgentStreaming/run``（DeepSeekAgentTransport）。
    private static let maxRetries = 2

    private static func isTransientNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// MacPaw 对 HTTP ≥400 抛 `OpenAIError.statusError`：仅 429 / 5xx 视为瞬态可重试
    ///（4xx 为客户端错误，重试无意义）。与 Agent 路径 `AgentTransportError.shouldRetryTransient` 对齐，
    /// 否则纪要 summary 流式遇服务端 5xx（常见瞬态）直接放弃，与 Agent 路径行为不一致。
    private static func isRetryableStatusError(_ error: Error) -> Bool {
        guard case OpenAIError.statusError(_, let statusCode) = error else { return false }
        return statusCode == 429 || (500...599).contains(statusCode)
    }

    public func streamText(
        system: String,
        messages: [AskChatTurn],
        model: String?,
        temperature: Double
    ) -> AsyncThrowingStream<String, Error> {
        let m = model ?? defaultModel
        let chatMessages: [ChatQuery.ChatCompletionMessageParam] = [
            .system(.init(content: .textContent(system)))
        ] + messages.map { turn in
            switch turn.role {
            case .user:
                return .user(.init(content: .string(turn.content)))
            case .assistant:
                return .assistant(.init(content: .textContent(turn.content)))
            }
        }
        let query = ChatQuery(
            messages: chatMessages,
            model: m,
            temperature: temperature,
            stream: true
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.runStream(query: query, model: m, attempt: 0, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 递归驱动单次流式尝试 + 瞬态重试；所有 `continuation.finish` 收敛于此。
    /// 重试守卫 `!produced`：已向下游产出任意 delta 后**绝不重试**
    ///（否则下游 ``MinutesPipeline`` 把 delta 重复拼进 summaryText、破坏 mergeStreamText）。
    private func runStream(
        query: ChatQuery,
        model: String,
        attempt: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        // 首 token 预算随重试递增（20→40→60s）：thinking 模型正文首 token 可能 >20s（前段
        // 全是 reasoning），固定预算会在同一位置连续误杀 3 次、整体判死但网络其实正常。
        let outcome = await performStreamOnce(
            query: query,
            continuation: continuation,
            firstTokenBudget: firstTokenTimeoutSeconds * Double(attempt + 1)
        )

        guard let error = outcome.error else {
            continuation.finish()
            return
        }

        let isRetryable = (error is FirstTokenTimeoutError)
            || ((error as? URLError).map(Self.isTransientNetworkError) ?? false)
            || Self.isRetryableStatusError(error)

        if !outcome.produced && attempt < Self.maxRetries && isRetryable {
            let delayNs = UInt64(300_000_000) * UInt64(attempt + 1)   // 300ms / 600ms
            try? await Task.sleep(nanoseconds: delayNs)
            if Task.isCancelled { continuation.finish(); return }
            await runStream(query: query, model: model, attempt: attempt + 1, continuation: continuation)
            return
        }

        RecapLog.provider.error("streamText model=\(model, privacy: .public) host=\(self.host, privacy: .public) 终结 produced=\(outcome.produced, privacy: .public): \(error.localizedDescription, privacy: .public)")
        continuation.finish(throwing: error)
    }

    /// 单次流式尝试：消费 `client.chatsStream`，与「首 token 超时」race。
    ///
    /// MacPaw 网络层失败（`.timedOut`/`.networkConnectionLost` 等）**原样透传** `URLError`
    ///（`StreamingSession.didCompleteWithError` 不包装，仅 HTTP ≥400 才包 `OpenAIError.statusError`），
    /// 故可被上层 `URLError` 分支精确捕获、纳入瞬态重试。
    ///
    /// 返回 `(produced, error)`：error==nil 表示流自然结束。结论以 actor 内 produced/timedOut 为准
    ///（首 chunk 与超时几乎同时到达时，produced 压制 timedOut，避免误判导致重试）。
    private func performStreamOnce(
        query: ChatQuery,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        firstTokenBudget: Double
    ) async -> (produced: Bool, error: Error?) {
        let attempt = StreamAttempt(continuation: continuation)
        return await Self.raceFirstToken(budget: firstTokenBudget, attempt: attempt) {
            do {
                for try await chunk in self.client.chatsStream(query: query) {
                    if Task.isCancelled { break }
                    if let t = chunk.choices.first?.delta.content, !t.isEmpty {
                        await attempt.yieldContent(t)
                    }
                }
            } catch is CancellationError {
                // 超时取消 / 外层取消：静默，结论由 outcome 表达。
            } catch {
                await attempt.recordConsumeError(error)
            }
        }
    }

    /// 首 token 竞速核心（提为静态纯结构，供回归测试）。
    ///
    /// 看门狗任务在「已产出首 token」后必须**解除武装**——挂起直至被取消，绝不自行完成：
    /// `group.next()` 会被任一子任务的完成唤醒并随即 `cancelAll()`。旧实现看门狗睡满预算
    /// 即完成，仍在健康产出的长流（摘要普遍超过首 token 预算的 20s）被掐断后按
    /// 「自然结束」finish——下游拿到静默截断的纪要。合法的完成只有两种：
    /// 真超时（预算内无首 token，需要 cancelAll 掐断消费）与被取消。
    static func raceFirstToken(
        budget: Double,
        attempt: StreamAttempt,
        consume: @escaping @Sendable () async -> Void
    ) async -> (produced: Bool, error: Error?) {
        await withTaskGroup(of: Void.self) { group in
            // 消费任务：持续 yield delta；随父 Task 取消而取消（结构化并发）。
            group.addTask {
                await consume()
            }
            // 看门狗：预算内未产出 → 判真超时（完成唤醒竞速，cancelAll 掐断消费）；
            // 已产出 → 解除武装挂起（消费先结束时由 cancelAll 唤醒收尾）。
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(budget))
                } catch {
                    return   // 消费先结束（或外层取消）提前唤醒：静默退出，无需动作
                }
                guard await attempt.resolveWatchdog(seconds: budget) else {
                    // 已产出：本任务不得完成（完成即唤醒竞速 → cancelAll 掐断健康流）。
                    // 挂到次日仅表「永不主动完成」——消费结束的 cancelAll 会立刻唤醒本任务。
                    try? await Task.sleep(for: .seconds(86_400))
                    return
                }
            }

            _ = await group.next()        // 消费完成 或 真超时，二者必居其一
            group.cancelAll()             // 超时则中断消费；消费先完成则解除看门狗
            await group.waitForAll()      // 等收尾，避免泄漏
        }
        return await attempt.outcome()
    }

    /// 单次流式尝试的可变状态。actor 串行化，消除「首 chunk 与超时」的竞态。
    /// internal 供 ``raceFirstToken`` 回归测试直接构造。
    actor StreamAttempt {
        private let continuation: AsyncThrowingStream<String, Error>.Continuation
        private var produced = false
        private var timedOut = false
        private var timeoutSeconds: Double = 0
        private var consumeError: Error?

        init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
            self.continuation = continuation
        }

        /// 产出 delta：已判超时后不再写入，避免重试导致下游重复拼接。
        func yieldContent(_ content: String) {
            guard !timedOut else { return }
            produced = true
            continuation.yield(content)
        }

        func recordConsumeError(_ error: Error) {
            if consumeError == nil { consumeError = error }
        }

        /// 看门狗醒来后的决断：真超时（仍未产出）标记并返回 true；已产出返回 false（解除武装）。
        /// 首 chunk 与超时几乎同时到达时 produced 优先，避免误判导致重试。
        func resolveWatchdog(seconds: Double) -> Bool {
            guard !produced else { return false }
            timedOut = true
            timeoutSeconds = seconds
            return true
        }

        func outcome() -> (produced: Bool, error: Error?) {
            if timedOut {
                return (false, FirstTokenTimeoutError(seconds: timeoutSeconds))
            }
            return (produced, consumeError)
        }
    }

    public func extractViaTool<T: Decodable & Sendable>(
        system: String, user: String, model: String?,
        toolName: String, toolDescription: String, parameters: JSONSchema, as type: T.Type,
        thinkingEnabled: Bool
    ) async throws -> T? {
        let m = model ?? defaultModel
        // DeepSeek V4 默认 Think mode，强制 tool_choice/function 会 400：
        // "Think mode does not support this tool choice"
        // 因此用原始 HTTP：关闭 thinking + 指定 function。
        return try await extractViaToolHTTP(
            model: m,
            system: system,
            user: user,
            toolName: toolName,
            toolDescription: toolDescription,
            parameters: parameters,
            thinkingEnabled: thinkingEnabled,
            as: type
        )
    }

    // MARK: - DeepSeek-safe tool call (thinking disabled)

    private func extractViaToolHTTP<T: Decodable & Sendable>(
        model: String,
        system: String,
        user: String,
        toolName: String,
        toolDescription: String,
        parameters: JSONSchema,
        thinkingEnabled: Bool,
        as type: T.Type
    ) async throws -> T? {
        let schemaObject = try encodeJSONSchema(parameters)
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            // P1：显式输出上限——厂商默认 max_tokens 偏小时，长会几十条待办的 arguments
            // 会被截断成坏 JSON（此前整场待办静默消失）。8192 对全部 OpenAI 兼容端点安全。
            "max_tokens": 8192,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "tools": [[
                "type": "function",
                "function": [
                    "name": toolName,
                    "description": toolDescription,
                    "parameters": schemaObject,
                ] as [String: Any],
            ]],
        ]
        // `thinking` 是 DeepSeek 专有参数：仅 DeepSeek 端点发送。云档（qwen 端点）与其余
        // BYOK 模板（qwen/glm/kimi/openai/claude/gemini/doubao/custom）一律不发——
        // 未知参数若被服务端严格校验会 400 且不可重试（按模板白名单而非排除清单判定，
        // 排除清单法会漏掉走 dashscope 兼容端点的 BYOK qwen 模板）。
        let isDeepSeekStyleAPI = id == "deepseek"
        if thinkingEnabled {
            // thinking-ON + tool_choice:auto（与 Agent 传输层同构，已验证可用）。
            // 靠 prompt+工具定义引导调用；模型若改走 content 输出 JSON，下方兜底解析。
            body["tool_choice"] = "auto"
            if isDeepSeekStyleAPI { body["thinking"] = ["type": "enabled"] }
        } else {
            // 最稳：强制 tool_choice + 关 thinking（DeepSeek thinking 拒绝强制 tool_choice）
            body["tool_choice"] = [
                "type": "function",
                "function": ["name": toolName],
            ]
            if isDeepSeekStyleAPI { body["thinking"] = ["type": "disabled"] }
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        // host 来自 parseBaseURL：URL 解析失败时回退为用户原始输入（可能含空格/非 ASCII），
        // 直接强解 URL(string:)! 会崩。构造失败时抛 badURL，由上层错误映射转友好提示。
        guard let url = URL(string: "https://\(host)\(basePath)/chat/completions") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = data
        req.timeoutInterval = 90

        // P1-B: 瞬态重试（URLError 瞬态 + 5xx，与流式 runStream 同构），避免单次网络抖动丢全部待办。
        let (respData, _) = try await performToolRequest(req)

        guard let root = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            // P1 修复：响应结构畸形不再静默 nil——调用方对 nil 按「成功、零待办」处理，
            // 整场行动项会无声消失；抛错走调用方既有 catch（.failed / 段失败计数，可见）。
            throw ExtractError.badResponse
        }

        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                let function = call["function"] as? [String: Any]
                let name = function?["name"] as? String
                guard name == toolName || name == nil else { continue }
                guard let args = function?["arguments"] as? String,
                      let argsData = args.data(using: .utf8) else { continue }
                if let decoded = try? JSONDecoder().decode(T.self, from: argsData) {
                    return decoded
                }
            }
        }

        // 兜底：模型把 JSON 写在 content 里（可能裹 ```json fence，先剥再解）
        if let content = message["content"] as? String {
            var s = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("```") {
                if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
                if let fence = s.range(of: "```", options: .backwards) {
                    s = String(s[..<fence.lowerBound])
                }
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let contentData = s.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(T.self, from: contentData) {
                return decoded
            }
        }
        // P1 修复：tool_calls 参数与 content 兜底都解不出（常见：arguments 被服务端输出
        // 上限截断成坏 JSON）——同上，抛错让调用方可见，不静默「零待办」。
        throw ExtractError.badResponse
    }

    /// 执行 tool-call HTTP 请求，瞬态错误重试（URLError `.timedOut`/`.networkConnectionLost`/
    /// `.notConnectedToInternet` + 429/5xx），与流式 ``runStream`` 同构：最多 `maxRetries+1` 次，
    /// 300ms/600ms 退避。其余 4xx 与非瞬态错误立即抛出；仅在 2xx 时返回 `(body, response)`。
    private func performToolRequest(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw ExtractError.badResponse }
                if (200..<300).contains(http.statusCode) { return (data, http) }
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                RecapLog.provider.error("extractViaTool HTTP \(http.statusCode): \(msg, privacy: .public)")
                if attempt < Self.maxRetries && (http.statusCode == 429 || (500..<600).contains(http.statusCode)) {
                    try? await Task.sleep(nanoseconds: UInt64(300_000_000) * UInt64(attempt + 1))
                    if Task.isCancelled { throw CancellationError() }
                    attempt += 1
                    continue
                }
                throw ExtractError.http(http.statusCode, msg)
            } catch let error as URLError where Self.isTransientNetworkError(error) {
                if attempt < Self.maxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(300_000_000) * UInt64(attempt + 1))
                    if Task.isCancelled { throw CancellationError() }
                    attempt += 1
                    continue
                }
                throw error
            }
        }
    }

    private func encodeJSONSchema(_ schema: JSONSchema) throws -> Any {
        let data = try JSONEncoder().encode(schema)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj
    }

    public enum ExtractError: Error, LocalizedError, Sendable {
        case badResponse
        case http(Int, String)

        public var errorDescription: String? {
            switch self {
            case .badResponse: return "待办提取无有效响应"
            case .http(let code, let body):
                let snippet = body.prefix(240)
                return "待办提取 HTTP \(code)：\(snippet)"
            }
        }
    }
}
