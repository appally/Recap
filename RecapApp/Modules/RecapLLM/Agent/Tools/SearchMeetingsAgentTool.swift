import Foundation
import RecapModels

/// 跨会议一级检索：找候选会议卡（排除本场）。
public struct SearchMeetingsAgentTool: AgentTool {
    public init() {}

    public var spec: AgentToolSpec {
        AgentToolSpec(
            name: "search_meetings",
            description: "在历史会议中按关键词找相关场次（不含本场）。命中后用 get_meeting_transcript / get_meeting_minutes 深入。",
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "query": { "type": "string", "description": "关键词，如客户名、议题、报价" },
                "since_days": { "type": "integer", "minimum": 1, "maximum": 365, "description": "只看最近 N 天" }
              },
              "required": ["query"],
              "additionalProperties": false
            }
            """
        )
    }

    public func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult {
        guard let workspace = context.workspace else {
            return AgentToolResult(
                contentForModel: "（跨会议检索不可用）",
                uiSummary: "无工作区",
                isEmpty: true
            )
        }
        let args = try AgentToolJSON.object(argumentsJSON)
        let query = (args["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            return AgentToolResult(contentForModel: "（查询为空）", uiSummary: "会议检索空查询", isEmpty: true)
        }
        var since: Date?
        if let days = args["since_days"] as? Int {
            let d = min(max(days, 1), 365)
            since = Calendar.current.date(byAdding: .day, value: -d, to: Date())
        } else if let days = args["since_days"] as? Double {
            let d = min(max(Int(days), 1), 365)
            since = Calendar.current.date(byAdding: .day, value: -d, to: Date())
        }

        let cards = await workspace.searchMeetings(
            query: query,
            excluding: context.currentMeetingId,
            since: since,
            limit: 6
        )
        if cards.isEmpty {
            return AgentToolResult(
                contentForModel: "（未找到相关历史会议。若库里只有本场，或关键词过窄，请换词重试。）",
                uiSummary: "历史会议 0 场",
                isEmpty: true
            )
        }
        let block = cards.map { card in
            var lines = [
                "[会议] \(card.shortDateText) · \(card.title) · id=\(card.id.uuidString)"
            ]
            if let tldr = card.tldr, !tldr.isEmpty {
                lines.append("  TLDR：\(tldr)")
            }
            lines.append("  命中：\(card.matchReason)；待办 \(card.actionItemCount)；遗留 \(card.openQuestionCount)")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")

        return AgentToolResult(
            contentForModel: block,
            uiSummary: "历史会议 \(cards.count) 场",
            isEmpty: false
        )
    }
}

/// 跨会议二级：进指定会议检索转写。
public struct GetMeetingTranscriptAgentTool: AgentTool {
    public init() {}

    public var spec: AgentToolSpec {
        AgentToolSpec(
            name: "get_meeting_transcript",
            description: "在指定历史会议的转写中按关键词检索（需先 search_meetings 拿到 meeting_id）",
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "meeting_id": { "type": "string", "description": "完整 UUID" },
                "query": { "type": "string" },
                "limit": { "type": "integer", "minimum": 1, "maximum": 8 }
              },
              "required": ["meeting_id", "query"],
              "additionalProperties": false
            }
            """
        )
    }

    public func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult {
        guard let workspace = context.workspace else {
            return AgentToolResult(contentForModel: "（跨会议检索不可用）", uiSummary: "无工作区", isEmpty: true)
        }
        let args = try AgentToolJSON.object(argumentsJSON)
        guard let meetingId = Self.parseUUID(args["meeting_id"]) else {
            return AgentToolResult(
                contentForModel: "未找到该会议，请先用 search_meetings（meeting_id 须为完整 UUID）",
                uiSummary: "无效会议 id",
                isEmpty: true
            )
        }
        if meetingId == context.currentMeetingId {
            return AgentToolResult(
                contentForModel: "这是本场会议，请改用 search_transcript。",
                uiSummary: "请用本场工具",
                isEmpty: true
            )
        }
        guard let label = await workspace.meetingLabel(meetingId: meetingId) else {
            return AgentToolResult(
                contentForModel: "未找到该会议，请先用 search_meetings",
                uiSummary: "会议不存在",
                isEmpty: true
            )
        }
        let query = (args["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            return AgentToolResult(contentForModel: "（查询为空）", uiSummary: "转写检索空查询", isEmpty: true)
        }
        var limit = args["limit"] as? Int ?? 6
        if let d = args["limit"] as? Double { limit = Int(d) }
        limit = min(max(limit, 1), 8)

        let hits = await workspace.searchTranscript(meetingId: meetingId, query: query, limit: limit)
        if hits.isEmpty {
            return AgentToolResult(
                contentForModel: "（\(label) 转写无命中，可换关键词或改用 get_meeting_minutes）",
                uiSummary: "跨会转写 0 条",
                isEmpty: true
            )
        }

        let block = hits.map { hit in
            "[\(label) · \(hit.timeLabel) \(hit.speakerName)] \(hit.text)"
        }.joined(separator: "\n")
        let citations: [AskCitation] = hits.map { hit in
            AskCitation(
                id: "x-\(meetingId.uuidString)-\(hit.id)",
                kind: .transcript,
                title: "\(label) · \(hit.timeLabel) \(hit.speakerName)",
                snippet: hit.text,
                startSeconds: nil // 跨会暂不跳转
            )
        }
        return AgentToolResult(
            contentForModel: block,
            uiSummary: "跨会转写 \(hits.count) 条",
            citations: citations,
            isEmpty: false
        )
    }

    public static func parseUUID(_ raw: Any?) -> UUID? {
        guard let s = raw as? String else { return nil }
        return UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct GetMeetingMinutesAgentTool: AgentTool {
    public init() {}

    public var spec: AgentToolSpec {
        AgentToolSpec(
            name: "get_meeting_minutes",
            description: "读取指定历史会议的纪要摘要（最高版本）",
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "meeting_id": { "type": "string", "description": "完整 UUID" }
              },
              "required": ["meeting_id"],
              "additionalProperties": false
            }
            """
        )
    }

    public func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult {
        guard let workspace = context.workspace else {
            return AgentToolResult(contentForModel: "（跨会议检索不可用）", uiSummary: "无工作区", isEmpty: true)
        }
        let args = try AgentToolJSON.object(argumentsJSON)
        guard let meetingId = GetMeetingTranscriptAgentTool.parseUUID(args["meeting_id"]) else {
            return AgentToolResult(
                contentForModel: "未找到该会议，请先用 search_meetings（meeting_id 须为完整 UUID）",
                uiSummary: "无效会议 id",
                isEmpty: true
            )
        }
        if meetingId == context.currentMeetingId {
            return AgentToolResult(
                contentForModel: "这是本场会议纪要，请直接依据卷宗材料回答。",
                uiSummary: "本场请勿跨查",
                isEmpty: true
            )
        }
        guard let label = await workspace.meetingLabel(meetingId: meetingId) else {
            return AgentToolResult(
                contentForModel: "未找到该会议，请先用 search_meetings",
                uiSummary: "会议不存在",
                isEmpty: true
            )
        }
        guard let summary = await workspace.minutes(meetingId: meetingId),
              let block = AskMeetingDossier.minutesBlock(summary: summary) else {
            return AgentToolResult(
                contentForModel: "\(label) 尚无纪要。",
                uiSummary: "跨会纪要空",
                isEmpty: true
            )
        }
        return AgentToolResult(
            contentForModel: "【\(label)】\n\(block)",
            uiSummary: "跨会纪要已取",
            citations: [
                AskCitation(
                    id: "xm-\(meetingId.uuidString)",
                    kind: .brief,
                    title: "历史纪要 · \(label)",
                    snippet: String(summary.tldr.prefix(80))
                )
            ],
            isEmpty: false
        )
    }
}

public struct ListActionItemsAgentTool: AgentTool {
    public init() {}

    public var spec: AgentToolSpec {
        AgentToolSpec(
            name: "list_action_items",
            description: "列出待办。写提醒前先调用以获取真实 action_item_ids。",
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "scope": { "type": "string", "enum": ["current", "all_open"] },
                "limit": { "type": "integer", "minimum": 1, "maximum": 20 }
              },
              "additionalProperties": false
            }
            """
        )
    }

    public func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult {
        let args = try AgentToolJSON.object(argumentsJSON)
        let scope = (args["scope"] as? String) ?? "current"
        var limit = args["limit"] as? Int ?? 12
        if let d = args["limit"] as? Double { limit = Int(d) }
        limit = min(max(limit, 1), 20)

        let items: [ActionItemSnapshot]
        if scope == "all_open" {
            if let workspace = context.workspace {
                items = await workspace.actionItems(meetingId: nil, openOnly: true, limit: limit)
            } else {
                items = Array(
                    context.actionItems
                        .filter { !$0.isDispatched && $0.statusRaw != "done" }
                        .prefix(limit)
                )
            }
        } else {
            items = Array(context.actionItems.prefix(limit))
        }

        if items.isEmpty {
            return AgentToolResult(
                contentForModel: "（无待办）",
                uiSummary: "待办 0 条",
                isEmpty: true
            )
        }
        let block = items.enumerated().map { idx, item in
            var line = "\(idx + 1). id=\(item.id.uuidString) · \(item.task)"
            if let owner = item.owner, !owner.isEmpty { line += " · \(owner)" }
            if let due = item.dueText { line += " · \(due)" }
            line += " · \(item.statusRaw)"
            if item.isDispatched { line += "（已分发）" }
            if scope == "all_open" { line += " · \(item.meetingTitle)" }
            return line
        }.joined(separator: "\n")

        return AgentToolResult(
            contentForModel: block,
            uiSummary: "待办 \(items.count) 条",
            isEmpty: false
        )
    }
}
