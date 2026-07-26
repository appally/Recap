import Foundation
import OpenAI

/// 待办结构化输出契约（null-safe：assignee/due/priority 不确定一律 nil，绝不编造）。
/// 经 tool calling 返回（json_schema 的 derivedJsonSchema 表达不了可空字段，故手写 JSONSchema）。
struct TodoListPayload: Codable, Sendable {
    struct Item: Codable, Sendable {
        let task: String
        let owner: String?
        let owner_source: String?
        let due: String?
        let priority: String?
        let confidence: Double
        let evidence_quote: String?
    }
    let action_items: [Item]

    /// null-safe 手写 JSONSchema：可空字段用 type:["string","null"]；全字段 required + additionalProperties:false。
    static let schema: JSONSchema = JSONSchema(
        .type(.object),
        .properties([
            "action_items": JSONSchema(
                .type(.array),
                .items(JSONSchema(
                    .type(.object),
                    .properties([
                        "task": JSONSchema(.type(.string), .description("要做的事，动词+具体对象")),
                        "owner": JSONSchema(.type(.types(["string", "null"])), .description("具名参会者；不清楚为 null")),
                        "owner_source": JSONSchema(.type(.types(["string", "null"])), .description("explicit 或 inferred")),
                        "due": JSONSchema(.type(.types(["string", "null"])), .description("ISO8601；未提及为 null，禁止推断")),
                        "priority": JSONSchema(.type(.types(["string", "null"])), .description("high/medium/low")),
                        "confidence": JSONSchema(.type(.number), .description("0..1 置信度")),
                        "evidence_quote": JSONSchema(.type(.types(["string", "null"])), .description("原文逐字，禁止改写"))
                    ]),
                    .required(["task", "owner", "owner_source", "due", "priority", "confidence", "evidence_quote"]),
                    .additionalProperties(JSONSchema.boolean(false))
                ))
            )
        ]),
        .required(["action_items"]),
        .additionalProperties(JSONSchema.boolean(false))
    )
}
