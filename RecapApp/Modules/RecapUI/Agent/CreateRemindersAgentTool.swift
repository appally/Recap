import Foundation
import RecapModels
import RecapLLM

/// MainActor 桥：持有当前会议以执行 EventKit 写入。
public final class CreateRemindersBridge: @unchecked Sendable {
    @MainActor public weak var meeting: Meeting?

    public init() {}

    @MainActor
    public func dispatch(ids: [UUID], meetingTitle: String) async -> (ok: Int, fail: Int, detail: String) {
        guard let meeting else {
            return (0, ids.count, "无会议上下文")
        }
        var ok = 0
        var fail = 0
        var notes: [String] = []
        for id in ids {
            guard let item = meeting.actionItems.first(where: { $0.id == id }) else {
                fail += 1
                notes.append("跳过未知 id")
                continue
            }
            do {
                let externalId = try await ReminderDispatcher.shared.dispatch(
                    item,
                    meetingTitle: meetingTitle
                )
                item.externalReminderId = externalId
                item.status = .dispatched
                ok += 1
            } catch {
                fail += 1
                notes.append(error.localizedDescription)
            }
        }
        let detail: String
        if fail == 0 {
            detail = "已写入 \(ok) 条"
        } else if ok == 0 {
            detail = "全部失败：\(notes.first ?? "未知错误")"
        } else {
            detail = "已写入 \(ok) 条，失败 \(fail) 条（\(notes.first ?? "部分失败")）"
        }
        return (ok, fail, detail)
    }
}

/// 首个写操作工具：仅对本场已有 ActionItem 建提醒，全程 HITL。
public struct CreateRemindersAgentTool: AgentTool {
    private let bridge: CreateRemindersBridge

    public init(bridge: CreateRemindersBridge) {
        self.bridge = bridge
    }

    public var requiresApproval: Bool { true }

    public var spec: AgentToolSpec {
        AgentToolSpec(
            name: "create_reminders",
            description: "将本场已有待办写入系统提醒事项。必须先 list_action_items 取得真实 id；只接受 action_item_ids。",
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "action_item_ids": {
                  "type": "array",
                  "items": { "type": "string" },
                  "description": "本场 ActionItem 的 UUID 列表"
                }
              },
              "required": ["action_item_ids"],
              "additionalProperties": false
            }
            """
        )
    }

    public func approvalSummary(argumentsJSON: String, context: AgentToolContext) -> String {
        let allowed = Set(context.actionItems.map(\.id))
        let ids = CreateRemindersArgs.parse(argumentsJSON, allowedIds: allowed)
        if ids.isEmpty {
            return "将向提醒事项写入待办（无有效 id，批准后也不会写入）"
        }
        let lines = ids.enumerated().compactMap { idx, id -> String? in
            guard let item = context.actionItems.first(where: { $0.id == id }) else { return nil }
            return "\(idx + 1). \(item.task)"
        }
        return "将向提醒事项写入 \(ids.count) 条待办：\n" + lines.joined(separator: "\n")
    }

    public func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult {
        let allowed = Set(context.actionItems.map(\.id))
        let ids = CreateRemindersArgs.parse(argumentsJSON, allowedIds: allowed)
        guard !ids.isEmpty else {
            return AgentToolResult(
                contentForModel: "无有效待办 id（须为本场已有 ActionItem）。请先 list_action_items。",
                uiSummary: "提醒未写入",
                isEmpty: true
            )
        }
        let result = await bridge.dispatch(ids: ids, meetingTitle: context.meetingTitle)
        return AgentToolResult(
            contentForModel: result.detail,
            uiSummary: result.ok > 0 ? "已写提醒 \(result.ok)" : "提醒未写入",
            isEmpty: result.ok == 0
        )
    }
}
