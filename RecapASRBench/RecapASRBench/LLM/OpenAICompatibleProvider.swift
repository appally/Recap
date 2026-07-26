import Foundation
import OpenAI

/// MacPaw/OpenAI 兼容实现：接 DeepSeek V4（及任何 OpenAI 兼容端点）。
/// 把 smoke test 的直连 MacPaw 收敛进 LLMProvider 协议。
/// Phase 2 再从 LLMProviderConfig 读 host/model/keychainAccount。
final class OpenAICompatibleProvider: LLMProvider {
    let id: String
    let defaultModel: String
    private let client: OpenAI

    init(id: String = "deepseek",
         apiKey: String,
         host: String = "api.deepseek.com",
         defaultModel: String = LLMPresets.deepSeekFlash) {
        self.id = id
        self.defaultModel = defaultModel
        self.client = OpenAI(configuration: .init(token: apiKey, host: host))
    }

    func streamText(system: String, user: String, model: String?, temperature: Double) -> AsyncThrowingStream<String, Error> {
        let m = model ?? defaultModel
        return AsyncThrowingStream { continuation in
            let task = Task {
                let query = ChatQuery(
                    messages: [
                        .system(.init(content: .textContent(system))),
                        .user(.init(content: .string(user)))
                    ],
                    model: m, temperature: temperature, stream: true
                )
                do {
                    for try await chunk in client.chatsStream(query: query) {
                        if let t = chunk.choices.first?.delta.content, !t.isEmpty {
                            continuation.yield(t)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func extractViaTool<T: Decodable & Sendable>(
        system: String, user: String, model: String?,
        toolName: String, toolDescription: String, parameters: JSONSchema, as type: T.Type
    ) async throws -> T? {
        let m = model ?? defaultModel
        let tool = ChatQuery.ChatCompletionToolParam(function: .init(
            name: toolName, description: toolDescription, parameters: parameters
        ))
        let query = ChatQuery(
            messages: [
                .system(.init(content: .textContent(system))),
                .user(.init(content: .string(user)))
            ],
            model: m,
            temperature: 0.0,
            toolChoice: .function(toolName),
            tools: [tool]
        )
        let result = try await client.chats(query: query)
        guard let args = result.choices.first?.message.toolCalls?.first?.function.arguments,
              let data = args.data(using: String.Encoding.utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
