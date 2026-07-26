import Foundation
import RecapModels

/// 读取 UI 侧落库结果（避免工具内写 SwiftData）。
public protocol ReviseMinutesCommitReading: Sendable {
    var lastCommitMessage: String? { get }
    func consumeCommitMessage() -> String?
}

/// 对话式修改本场纪要（HITL；工具内不写库，由 UI 确认后经 Bridge 落库）。
public struct ReviseMinutesAgentTool: AgentTool {
    private let commitReader: (any ReviseMinutesCommitReading)?

    public init(commitReader: (any ReviseMinutesCommitReading)? = nil) {
        self.commitReader = commitReader
    }

    public var requiresApproval: Bool { true }

    public var spec: AgentToolSpec {
        AgentToolSpec(
            name: "revise_minutes",
            description: "按用户要求修改本场纪要。只传需要改的字段，其余为 null。改前应 search_transcript 取证据。写入需用户确认。",
            parametersJSON: MinutesReviser.schemaJSON
        )
    }

    public func approvalSummary(argumentsJSON: String, context: AgentToolContext) -> String {
        guard let base = context.currentMinutes,
              let payload = MinutesReviser.parseArgumentsJSON(argumentsJSON) else {
            return "修改纪要（参数不完整）"
        }
        let revised = MinutesDiff.apply(payload, to: base)
        let diffs = MinutesDiff.compute(base: base, revised: revised, notes: payload.changeNotes)
            .filter(\.changed)
        if diffs.isEmpty {
            return "修改纪要（无实质改动）"
        }
        let parts = diffs.map(\.displayName)
        return "修改纪要：" + parts.joined(separator: "、")
    }

    public func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult {
        if let msg = commitReader?.consumeCommitMessage(), !msg.isEmpty {
            return AgentToolResult(
                contentForModel: msg,
                uiSummary: msg,
                isEmpty: false
            )
        }
        guard context.currentMinutes != nil else {
            return AgentToolResult(
                contentForModel: "本场尚无纪要，无法改写。",
                uiSummary: "无纪要",
                isEmpty: true
            )
        }
        guard MinutesReviser.parseArgumentsJSON(argumentsJSON) != nil else {
            return AgentToolResult(
                contentForModel: "改写参数无法解析，请重试。",
                uiSummary: "纪要改写失败",
                isEmpty: true
            )
        }
        return AgentToolResult(
            contentForModel: "用户已确认纪要修改。",
            uiSummary: "纪要已确认",
            isEmpty: false
        )
    }
}
