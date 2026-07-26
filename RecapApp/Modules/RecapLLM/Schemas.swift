import Foundation
import OpenAI

/// 待办结构化输出契约（null-safe：assignee/due/priority 不确定一律 nil，绝不编造）。
/// 经 tool calling 返回（手写 JSONSchema，表达可空字段）。
public struct TodoListPayload: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public let task: String
        public let owner: String?
        public let owner_source: String?
        public let due: String?
        public let priority: String?
        public let confidence: Double
        public let evidence_quote: String?
        /// 证据句在转写中的开始秒数；无法定位则为 null。
        public let start_seconds: Double?

        public init(task: String,
                    owner: String?,
                    owner_source: String?,
                    due: String?,
                    priority: String?,
                    confidence: Double,
                    evidence_quote: String?,
                    start_seconds: Double? = nil) {
            self.task = task
            self.owner = owner
            self.owner_source = owner_source
            self.due = due
            self.priority = priority
            self.confidence = confidence
            self.evidence_quote = evidence_quote
            self.start_seconds = start_seconds
        }
    }

    public let action_items: [Item]

    public init(action_items: [Item]) {
        self.action_items = action_items
    }

    /// null-safe 手写 JSONSchema：可空字段用 type:["string","null"]；全字段 required + additionalProperties:false。
    public static let schema: JSONSchema = JSONSchema(
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
                        "evidence_quote": JSONSchema(.type(.types(["string", "null"])), .description("原文逐字，禁止改写")),
                        "start_seconds": JSONSchema(
                            .type(.types(["number", "null"])),
                            .description("证据句在转写中的开始秒数；无法定位则为 null，禁止猜测")
                        ),
                    ]),
                    .required([
                        "task", "owner", "owner_source", "due", "priority",
                        "confidence", "evidence_quote", "start_seconds",
                    ]),
                    .additionalProperties(JSONSchema.boolean(false))
                ))
            )
        ]),
        .required(["action_items"]),
        .additionalProperties(JSONSchema.boolean(false))
    )
}
