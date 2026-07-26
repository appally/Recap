import Foundation
import OpenAI
import RecapModels

/// MacPaw/OpenAI 兼容实现：接 DeepSeek V4（及任何 OpenAI 兼容端点）。
public final class OpenAICompatibleProvider: LLMProvider, @unchecked Sendable {
    public let id: String
    public let defaultModel: String
    private let client: OpenAI
    private let apiKey: String
    private let host: String
    private let basePath: String

    /// - Parameter baseURL: 完整 OpenAI 兼容基址（含路径，如
    ///   `https://dashscope.aliyuncs.com/compatible-mode/v1`）。自动拆 host + basePath；
    ///   MacPaw 与原始 HTTP 都走全路径，修子路径被吞（旧实现在此丢 qwen/glm/doubao/gemini/claude 的路径）。
    public init(id: String = "deepseek",
                apiKey: String,
                baseURL: String = "https://api.deepseek.com",
                defaultModel: String = LLMPresets.deepSeekFlash) {
        self.id = id
        self.defaultModel = defaultModel
        self.apiKey = apiKey
        let parsed = Self.parseBaseURL(baseURL)
        self.host = parsed.host
        self.basePath = parsed.basePath
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
        return AsyncThrowingStream { continuation in
            let task = Task {
                let query = ChatQuery(
                    messages: chatMessages,
                    model: m,
                    temperature: temperature,
                    stream: true
                )
                do {
                    for try await chunk in client.chatsStream(query: query) {
                        if let t = chunk.choices.first?.delta.content, !t.isEmpty {
                            continuation.yield(t)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
        if thinkingEnabled {
            // thinking-ON + tool_choice:auto（与 Agent 传输层同构，已验证可用）。
            // 靠 prompt+工具定义引导调用；模型若改走 content 输出 JSON，下方兜底解析。
            body["tool_choice"] = "auto"
            body["thinking"] = ["type": "enabled"]
        } else {
            // 最稳：强制 tool_choice + 关 thinking（DeepSeek thinking 拒绝强制 tool_choice）
            body["tool_choice"] = [
                "type": "function",
                "function": ["name": toolName],
            ]
            body["thinking"] = ["type": "disabled"]
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: "https://\(host)\(basePath)/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = data
        req.timeoutInterval = 90

        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ExtractError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: respData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ExtractError.http(http.statusCode, msg)
        }

        guard let root = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
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

        // 兜底：模型把 JSON 写在 content 里
        if let content = message["content"] as? String,
           let contentData = content.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(T.self, from: contentData) {
            return decoded
        }
        return nil
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
