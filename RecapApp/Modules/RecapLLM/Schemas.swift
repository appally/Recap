import Foundation
import OpenAI

/// 待办结构化输出契约（null-safe：assignee/due_text 不确定一律 nil，绝不编造）。
/// 经 tool calling 返回（手写 JSONSchema，表达可空字段）。
public struct TodoListPayload: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public let task: String
        public let owner: String?
        public let owner_source: String?
        public let due_text: String?
        public let confidence: Double
        public let evidence_quote: String?
        /// 证据句在转写中的开始秒数；无法定位则为 null。
        public let start_seconds: Double?

        public init(task: String,
                    owner: String?,
                    owner_source: String?,
                    due_text: String?,
                    confidence: Double,
                    evidence_quote: String?,
                    start_seconds: Double? = nil) {
            self.task = task
            self.owner = owner
            self.owner_source = owner_source
            self.due_text = due_text
            self.confidence = confidence
            self.evidence_quote = evidence_quote
            self.start_seconds = start_seconds
        }

        /// 容错解码：模型输出对 schema 有轻微偏差（confidence 置 null/缺失、owner 写成数字等）
        /// 时**逐字段**降级，而非让整场待办解码失败被吞成「成功、零待办」。
        /// task 缺失/非字符串的条目解码为空串，由消费端过滤。
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            task = (try? c.decode(String.self, forKey: .task)) ?? ""
            owner = try? c.decodeIfPresentStringTolerant(forKey: .owner)
            owner_source = try? c.decodeIfPresentStringTolerant(forKey: .owner_source)
            due_text = try? c.decodeIfPresentStringTolerant(forKey: .due_text)
            evidence_quote = try? c.decodeIfPresentStringTolerant(forKey: .evidence_quote)
            if let d = try? c.decode(Double.self, forKey: .confidence) {
                confidence = d
            } else if let s = try? c.decode(String.self, forKey: .confidence),
                      let d = Double(s) {
                confidence = d
            } else {
                confidence = 0.5   // 缺失/不可解析：中性置信，不丢条目
            }
            if let d = try? c.decode(Double.self, forKey: .start_seconds) {
                start_seconds = d
            } else if let s = try? c.decode(String.self, forKey: .start_seconds), let d = Double(s) {
                start_seconds = d
            } else {
                start_seconds = nil
            }
        }
    }

    public let action_items: [Item]

    public init(action_items: [Item]) {
        self.action_items = action_items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action_items = (try? c.decode([Item].self, forKey: .action_items)) ?? []
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
                        "due_text": JSONSchema(.type(.types(["string", "null"])), .description("相对日期文本，照搬转写原话（如「下周三」「月底」「本周五」「3号」）；不要换算成绝对日期；未提及为 null")),
                        "confidence": JSONSchema(.type(.number), .description("0..1 置信度")),
                        "evidence_quote": JSONSchema(.type(.types(["string", "null"])), .description("原文逐字，禁止改写")),
                        "start_seconds": JSONSchema(
                            .type(.types(["number", "null"])),
                            .description("证据句在转写中的开始秒数；无法定位则为 null，禁止猜测")
                        ),
                    ]),
                    .required([
                        "task", "owner", "owner_source", "due_text",
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

extension KeyedDecodingContainer {
    /// 字符串字段容错：null/缺失返回 nil；数字/布尔强转字符串（模型偶发把人名/日期写成数字）。
    func decodeIfPresentStringTolerant(forKey key: Key) throws -> String? {
        guard contains(key) else { return nil }
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        if let d = try? decode(Double.self, forKey: key) { return String(d) }
        if let b = try? decode(Bool.self, forKey: key) { return String(b) }
        return nil
    }
}
