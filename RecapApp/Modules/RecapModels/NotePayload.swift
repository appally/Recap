import Foundation

/// 笔记层模板产物载荷（`AIOutput.kind == .note`）。
///
/// 对外纪要 / 跟进邮件 / 周报 / 思维导图 等都复用此结构，按 `skillId` 路由渲染器
/// （思维导图的 body 为缩进大纲 markdown，由渲染器解析成树）。
public struct NotePayload: Sendable, Codable, Hashable {
    public let skillId: String
    public let title: String
    public let body: String        // markdown 正文
    public let modelId: String

    public init(skillId: String, title: String, body: String, modelId: String) {
        self.skillId = skillId
        self.title = title
        self.body = body
        self.modelId = modelId
    }
}

public extension AIOutput {
    /// 解码笔记产物；非 `.note` 或解码失败返回 nil。
    var notePayload: NotePayload? {
        guard kind == .note else { return nil }
        return try? JSONDecoder().decode(NotePayload.self, from: payloadData)
    }
}
