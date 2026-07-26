import Foundation
import SwiftData

/// LLM 产出类型。
enum OutputKind: String, Codable, Sendable {
    case summary     // 会议纪要
    case todos       // 待办
    case decisions   // 决策
    case draft       // agent 起草的方案/调研（待办跟进）
}

/// 一次 LLM 产出（按 类型 + 版本 + prompt 指纹 存），可多版本对比/重生。
@Model
final class AIOutput {
    @Attribute(.unique) var id: UUID
    var kind: OutputKind
    var payloadData: Data          // 结构化结果 JSON（纪要/待办/决策/草稿）
    var modelId: String
    var promptHash: String
    var version: Int
    var createdAt: Date
    var meeting: Meeting?

    init(id: UUID = UUID(),
         kind: OutputKind,
         payloadData: Data,
         modelId: String,
         promptHash: String,
         version: Int = 1,
         meeting: Meeting? = nil) {
        self.id = id
        self.kind = kind
        self.payloadData = payloadData
        self.modelId = modelId
        self.promptHash = promptHash
        self.version = version
        self.createdAt = Date()
        self.meeting = meeting
    }
}
