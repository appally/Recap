import Foundation
import RecapModels

/// 本场转写检索工具（包装 `SearchTranscriptTool`）。
public struct SearchTranscriptAgentTool: AgentTool {
    public init() {}

    public var spec: AgentToolSpec {
        AgentToolSpec(
            name: "search_transcript",
            description: "在本场会议转写中按关键词检索相关发言片段",
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "query": { "type": "string", "description": "检索关键词或短句" },
                "limit": { "type": "integer", "minimum": 1, "maximum": 8 }
              },
              "required": ["query"],
              "additionalProperties": false
            }
            """
        )
    }

    public func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult {
        let args = try AgentToolJSON.object(argumentsJSON)
        let query = (args["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            return AgentToolResult(contentForModel: "（查询为空）", uiSummary: "转写检索空查询", isEmpty: true)
        }
        var limit = args["limit"] as? Int ?? 6
        limit = min(max(limit, 1), 8)

        // 会中：近窗加成让「刚说的」胜出（与 prepareLocal 同口径）。
        let liveNow: Double? = (context.phase == .live)
            ? context.segments.map(\.endSeconds).max()
            : nil
        let hits = SearchTranscriptTool.search(
            query: query,
            segments: context.segments,
            speakers: context.speakers,
            limit: limit,
            nowSeconds: liveNow
        )
        if hits.isEmpty {
            return AgentToolResult(
                contentForModel: "（本场转写无命中）",
                uiSummary: "转写 0 条",
                isEmpty: true
            )
        }
        let block = hits.map { hit in
            "[\(hit.timeLabel) \(hit.speakerName)] \(hit.text)"
        }.joined(separator: "\n")
        return AgentToolResult(
            contentForModel: block,
            uiSummary: "转写命中 \(hits.count) 条",
            citations: hits.map(AskCitation.from),
            isEmpty: false
        )
    }
}

/// 会前底稿检索工具（包装 `SearchBriefTool`）。
public struct SearchBriefAgentTool: AgentTool {
    public init() {}

    public var spec: AgentToolSpec {
        AgentToolSpec(
            name: "search_brief",
            description: "在会前底稿/议案原文中按关键词检索片段",
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "query": { "type": "string" },
                "limit": { "type": "integer", "minimum": 1, "maximum": 6 }
              },
              "required": ["query"],
              "additionalProperties": false
            }
            """
        )
    }

    public func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult {
        let args = try AgentToolJSON.object(argumentsJSON)
        let query = (args["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            return AgentToolResult(contentForModel: "（查询为空）", uiSummary: "底稿检索空查询", isEmpty: true)
        }
        var limit = args["limit"] as? Int ?? 4
        limit = min(max(limit, 1), 6)

        let hits = SearchBriefTool.search(
            query: query,
            sources: context.briefSources,
            limit: limit
        )
        if hits.isEmpty {
            return AgentToolResult(
                contentForModel: "（底稿无命中）",
                uiSummary: "底稿 0 条",
                isEmpty: true
            )
        }
        let block = hits.map { hit in
            "[\(hit.role.displayName) · \(hit.sourceTitle)] \(hit.text)"
        }.joined(separator: "\n")
        return AgentToolResult(
            contentForModel: block,
            uiSummary: "底稿命中 \(hits.count) 条",
            citations: hits.map(AskCitation.from),
            isEmpty: false
        )
    }
}

/// 联网检索工具（包装 `SearchWebTool`）。仅在 webEnabled 时注册。
public struct SearchWebAgentTool: AgentTool {
    public init() {}

    public var spec: AgentToolSpec {
        AgentToolSpec(
            name: "search_web",
            description: "互联网搜索；用于外部事实、官网、竞品、最新动态等",
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "query": { "type": "string", "description": "适合搜索引擎的短查询" }
              },
              "required": ["query"],
              "additionalProperties": false
            }
            """
        )
    }

    public func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult {
        let args = try AgentToolJSON.object(argumentsJSON)
        let raw = (args["query"] as? String) ?? ""
        let query = AskWebQueryBuilder.sanitizeConversational(raw)
        guard !query.isEmpty else {
            return AgentToolResult(contentForModel: "（查询为空）", uiSummary: "联网空查询", isEmpty: true)
        }
        let hits = try await SearchWebTool.search(query: query)
        if hits.isEmpty {
            return AgentToolResult(
                contentForModel: "（联网无结果）",
                uiSummary: "联网 0 条",
                isEmpty: true
            )
        }
        let block = hits.map { hit in
            "- \(hit.title)\n  \(hit.url)\n  \(hit.content)"
        }.joined(separator: "\n")
        return AgentToolResult(
            contentForModel: block,
            uiSummary: "联网 \(hits.count) 条",
            citations: hits.map(AskCitation.from),
            isEmpty: false
        )
    }
}
