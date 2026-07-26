import Foundation
import RecapModels

/// Ask 侧编排工具：按 id 跑命名技能（嵌套执行不含 `run_skill`）。
public struct RunSkillAgentTool: AgentTool {
    private let catalog: AgentSkillCatalog

    public init(catalog: AgentSkillCatalog = .bundledOrEmpty) {
        self.catalog = catalog
    }

    public var spec: AgentToolSpec {
        let ids = catalog.skills.map(\.id).sorted().joined(separator: ", ")
        let list = ids.isEmpty ? "（无内置技能）" : ids
        return AgentToolSpec(
            name: "run_skill",
            description: "运行内置会议文稿技能（如写跟进邮件、提取行动清单）。可用 skill_id：\(list)",
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "skill_id": { "type": "string", "description": "技能 id，如 action-list" },
                "hint": { "type": "string", "description": "可选补充说明" }
              },
              "required": ["skill_id"],
              "additionalProperties": false
            }
            """
        )
    }

    public func invoke(argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolResult {
        let args = try AgentToolJSON.object(argumentsJSON)
        let skillId = (args["skill_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !skillId.isEmpty else {
            return AgentToolResult(
                contentForModel: "（skill_id 为空）",
                uiSummary: "技能参数无效",
                isEmpty: true
            )
        }
        guard let skill = catalog.skill(id: skillId) else {
            return AgentToolResult(
                contentForModel: "未知技能：\(skillId)。可用：\(catalog.skills.map(\.id).joined(separator: ", "))",
                uiSummary: "未知技能",
                isEmpty: true
            )
        }
        let hint = args["hint"] as? String
        do {
            let outcome = try await AgentSkillRunner.runDetailed(
                skill: skill,
                context: context,
                hint: hint
            )
            return AgentToolResult(
                contentForModel: outcome.text,
                uiSummary: "技能 · \(skill.name)",
                isEmpty: outcome.text.isEmpty,
                budgetCost: outcome.budgetCost
            )
        } catch {
            return AgentToolResult(
                contentForModel: "技能失败：\(error.localizedDescription)",
                uiSummary: "技能失败 · \(skill.name)",
                isEmpty: true
            )
        }
    }
}
