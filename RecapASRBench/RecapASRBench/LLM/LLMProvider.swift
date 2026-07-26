import Foundation
import OpenAI

/// 统一 LLM 接入抽象（方案 §2.1）。Phase 1：OpenAICompatibleProvider（MacPaw/DeepSeek V4）。
/// 意图级接口：流式文本 + tool calling 结构化抽取。Phase 2 加 BYOK/其它厂商时实现同一协议。
protocol LLMProvider: Sendable {
    var id: String { get }
    var defaultModel: String { get }

    /// 流式文本（纪要渐进渲染用）。yield 文本增量。
    func streamText(system: String, user: String, model: String?, temperature: Double) -> AsyncThrowingStream<String, Error>

    /// 通过 tool calling 做结构化抽取（null-safe 友好：json_schema 的 derivedJsonSchema 表达不了可空字段，
    /// 故 null-safe 待办走 tool 参数手写 schema）。强制调用 toolName，把参数 JSON 解码为 T。
    func extractViaTool<T: Decodable & Sendable>(
        system: String, user: String, model: String?,
        toolName: String, toolDescription: String, parameters: JSONSchema, as type: T.Type
    ) async throws -> T?
}
