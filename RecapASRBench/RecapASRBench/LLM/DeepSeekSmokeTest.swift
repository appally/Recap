import Foundation
import OpenAI

/// DeepSeek + MacPaw 兼容性实测，三项关键能力（Phase 1「首日实测」）：
/// ① 流式 chat（连通性）② structured output（json_schema strict，待办/纪要结构化地基）
/// ③ tool calling（function calling，agent 工具调用地基）
/// apiKey 由 UI 层从 Keychain 取后传入，本类型不存凭证。
enum DeepSeekSmokeTest {

    // MARK: - ① 流式 chat（连通性）
    static func streamChat(
        apiKey: String,
        model: String = LLMPresets.deepSeekFlash,
        prompt: String = "用一句话介绍你自己，并说明你是哪个模型。"
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let config = OpenAI.Configuration(token: apiKey, host: "api.deepseek.com")
                let client = OpenAI(configuration: config)
                let query = ChatQuery(
                    messages: [
                        .system(.init(content: .textContent("你是 Recap 会议助手，用简体中文回答。"))),
                        .user(.init(content: .string(prompt)))
                    ],
                    model: model, temperature: 0.0, stream: true
                )
                do {
                    for try await chunk in client.chatsStream(query: query) {
                        if let text = chunk.choices.first?.delta.content, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - ② Structured Output（json_schema strict）
    /// 验证 DeepSeek 是否支持 response_format=json_schema strict。
    /// 不支持则 UI 显示原始返回/错误 -> 届时退 function calling 做结构化（方案 §2.3 备选）。
    private struct TodoExtract: Codable, JSONSchemaConvertible {
        let topic: String
        let action_items: [String]
        static var example: TodoExtract { .init(topic: "Q3营销", action_items: ["小王下周三出方案"]) }
    }

    static func structuredOutput(apiKey: String) async throws -> String {
        let client = OpenAI(configuration: .init(token: apiKey, host: "api.deepseek.com"))
        let query = ChatQuery(
            messages: [
                .system(.init(content: .textContent("你是会议纪要助手。从用户给出的会议片段提取【主题】与【待办列表】，严格输出 JSON，不要输出任何多余文字。"))),
                .user(.init(content: .string("今天讨论 Q3 营销。小王说他下周三前出方案。李姐负责联系媒体。")))
            ],
            model: LLMPresets.deepSeekFlash,
            responseFormat: .jsonSchema(.init(name: "todo_extract",
                                              schema: .derivedJsonSchema(TodoExtract.self),
                                              strict: true)),
            temperature: 0.0
        )
        let result = try await client.chats(query: query)
        let raw = result.choices.first?.message.content ?? "(空)"
        if let data = raw.data(using: String.Encoding.utf8),
           let parsed = try? JSONDecoder().decode(TodoExtract.self, from: data) {
            return "✓ strict json_schema 解码成功\n主题: \(parsed.topic)\n待办: \(parsed.action_items.joined(separator: " / "))\n\n原始 JSON:\n\(raw)"
        }
        return "⚠️ 未按 schema 解码成功（可能 DeepSeek 不支持 strict json_schema）\n原始返回:\n\(raw)"
    }

    // MARK: - ③ Tool Calling（function calling）
    /// 验证 DeepSeek function calling（agent 工具调用地基）。强制调用 create_reminder。
    static func toolCalling(apiKey: String) async throws -> String {
        let client = OpenAI(configuration: .init(token: apiKey, host: "api.deepseek.com"))
        let params = JSONSchema(
            .type(.object),
            .properties([
                "task": JSONSchema(.type(.string), .description("待办内容")),
                "due":  JSONSchema(.type(.string), .description("截止时间 ISO8601；未提及留空"))
            ]),
            .required(["task"])
        )
        let tool = ChatQuery.ChatCompletionToolParam(function: .init(
            name: "create_reminder",
            description: "创建一条会议待办提醒",
            parameters: params,
            strict: true
        ))
        let query = ChatQuery(
            messages: [
                .system(.init(content: .textContent("你是会议助手。识别用户发言中的待办并调用 create_reminder 工具创建。"))),
                .user(.init(content: .string("好，那我明天下午把设计稿发给产品经理审一下。")))
            ],
            model: LLMPresets.deepSeekFlash,
            temperature: 0.0,
            toolChoice: .function("create_reminder"),
            tools: [tool]
        )
        let result = try await client.chats(query: query)
        let msg = result.choices.first?.message
        if let fn = msg?.toolCalls?.first?.function {
            return "✓ function calling 触发\n函数: \(fn.name)\n参数: \(fn.arguments)"
        }
        return "⚠️ 未触发工具调用（finishReason: \(result.choices.first?.finishReason ?? "?")）\n内容: \(msg?.content ?? "(空)")"
    }
}
