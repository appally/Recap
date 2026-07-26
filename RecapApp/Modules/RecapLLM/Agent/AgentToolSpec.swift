import Foundation

/// 工具 schema 声明（仅数据，无执行）。
///
/// `parametersJSON` 用已序列化的 JSON Schema **字符串**，而非 MacPaw `JSONSchema`：
/// 传输层要能服务非 OpenAI 端点，且 `Schemas.swift` 手写 JSONSchema 在可空字段上表达受限。
/// 各工具在 029 自行产出 schema 字符串。
public struct AgentToolSpec: Sendable, Hashable {
    /// 工具名；约定 `^[a-zA-Z0-9_-]{1,64}$`。
    public let name: String
    public let description: String
    /// JSON Schema 对象的已序列化 JSON 字符串。
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}
