import Foundation
import RecapModels

/// 读取公开网页正文（Jina Reader）；仅在联网开启时注册。
public struct ReadURLAgentTool: AgentTool {
    public init() {}

    public var spec: AgentToolSpec {
        AgentToolSpec(
            name: "read_url",
            description: "读取公开网页的纯文本正文（http/https）。用于在 search_web 之后深读某个链接。",
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "url": { "type": "string", "description": "完整 http/https URL" }
              },
              "required": ["url"],
              "additionalProperties": false
            }
            """
        )
    }

    public func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult {
        let args = try AgentToolJSON.object(argumentsJSON)
        let raw = (args["url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, let url = URL(string: raw) else {
            return AgentToolResult(contentForModel: "（URL 无效）", uiSummary: "读网页失败", isEmpty: true)
        }
        guard ReadURLTool.isAllowed(url) else {
            return AgentToolResult(
                contentForModel: "不允许读取该 URL（仅支持公网 http/https，拒绝内网/localhost）。",
                uiSummary: "URL 被拒",
                isEmpty: true
            )
        }
        do {
            let result = try await ReadURLTool.fetchText(url, maxChars: 1_200)
            let cite = AskCitation.from(WebHit(
                title: url.host ?? url.absoluteString,
                url: url.absoluteString,
                content: String(result.text.prefix(160))
            ))
            return AgentToolResult(
                contentForModel: "来源：\(url.absoluteString)\n\n\(result.text)",
                uiSummary: result.truncated ? "已读网页（截断）" : "已读网页",
                citations: [cite],
                isEmpty: result.text.isEmpty
            )
        } catch {
            return AgentToolResult(
                contentForModel: "读取失败：\(error.localizedDescription)",
                uiSummary: "读网页失败",
                isEmpty: true
            )
        }
    }
}
