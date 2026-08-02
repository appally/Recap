import Foundation

/// 可配置技能：system prompt + 工具白名单 + 模型角色 + 步数。
public struct AgentSkill: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let icon: String
    /// 产出形态（模板分类脊柱的辅轴）：recap / extract / write / visualize。
    public let groupId: String
    public let groupTitle: String
    /// 场景域（模板分类脊柱的主轴）：通用会议 / 客户与销售 / …
    public let scenario: TemplateScenario
    public let systemPrompt: String
    public let allowedTools: Set<String>
    public let modelRole: AgentModelRole
    public let maxSteps: Int
    /// 采样温度覆盖（nil = 用 AgentKernel 默认 0.2）。结构化产出技能（如 mermaid-flowchart）
    /// 可设 0.0 以降低语法飘移。仅是请求参数，不进 system prompt，不影响 prompt caching。
    public let temperature: Double?

    public init(
        id: String,
        name: String,
        description: String,
        icon: String,
        groupId: String,
        groupTitle: String,
        scenario: TemplateScenario = .general,
        systemPrompt: String,
        allowedTools: Set<String>,
        modelRole: AgentModelRole = .quick,
        maxSteps: Int = 3,
        temperature: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.groupId = groupId
        self.groupTitle = groupTitle
        self.scenario = scenario
        self.systemPrompt = systemPrompt
        self.allowedTools = allowedTools
        self.modelRole = modelRole
        self.maxSteps = min(max(maxSteps, 1), 6)
        self.temperature = temperature
    }
}

public extension AgentBudget {
    /// 技能任务预算：步数硬顶 6。
    static func skill(maxSteps: Int) -> AgentBudget {
        let steps = min(max(maxSteps, 1), 6)
        return AgentBudget(
            maxSteps: steps,
            maxToolCalls: steps + 2,
            wallClock: TimeInterval(20 * steps),
            maxToolResultChars: 1_200,
            maxTotalToolChars: 6_000
        )
    }
}
