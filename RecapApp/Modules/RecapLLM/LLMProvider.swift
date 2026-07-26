import Foundation
import OpenAI

/// 统一 LLM 接入抽象（产品方案 §2.1）。
/// Phase 1：OpenAICompatibleProvider（MacPaw / DeepSeek V4）。
/// 意图级接口：流式文本 + tool calling 结构化抽取。
public protocol LLMProvider: Sendable {
    var id: String { get }
    var defaultModel: String { get }
    /// 高质量任务（纪要/调研）用的强模型；默认与 `defaultModel` 同款。
    var summaryModel: String { get }

    /// 流式文本（支持多轮 history）。`messages` 最后一条应为当前 user（含证据块）。
    func streamText(
        system: String,
        messages: [AskChatTurn],
        model: String?,
        temperature: Double
    ) -> AsyncThrowingStream<String, Error>

    /// 通过 tool calling 做结构化抽取。
    /// null-safe 待办走手写 JSONSchema（derivedJsonSchema 表达不了可空字段）。
    ///
    /// - Parameter thinkingEnabled: true = thinking-on + `tool_choice:"auto"`（与 Agent 传输层
    ///   `ChatCompletionsCodec` 同构，已验证可用；质量更高，靠 prompt+工具定义引导调用 + content
    ///   JSON 兜底保稳）。false（默认，最稳）= 强制 `tool_choice` + 关 thinking。
    func extractViaTool<T: Decodable & Sendable>(
        system: String, user: String, model: String?,
        toolName: String, toolDescription: String, parameters: JSONSchema, as type: T.Type,
        thinkingEnabled: Bool
    ) async throws -> T?
}

extension LLMProvider {
    /// 默认与 `defaultModel` 同款；`OpenAICompatibleProvider` 覆盖为厂商强模型。
    public var summaryModel: String { defaultModel }

    /// 单轮便捷入口（纪要 / 技能等）；委托为仅含一条 user 的多轮 API。
    public func streamText(
        system: String,
        user: String,
        model: String?,
        temperature: Double
    ) -> AsyncThrowingStream<String, Error> {
        streamText(
            system: system,
            messages: [AskChatTurn(role: .user, content: user)],
            model: model,
            temperature: temperature
        )
    }
}
