import Foundation

public struct AgentSkillGroup: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let skills: [AgentSkill]

    public init(id: String, title: String, skills: [AgentSkill]) {
        self.id = id
        self.title = title
        self.skills = skills
    }
}

/// 按**场景域**聚合的模板分组（探索 Tab 的分组单元）。
public struct AgentScenarioGroup: Sendable, Hashable, Identifiable {
    public let scenario: TemplateScenario
    public let skills: [AgentSkill]

    public init(scenario: TemplateScenario, skills: [AgentSkill]) {
        self.scenario = scenario
        self.skills = skills
    }

    public var id: String { scenario.id }
    public var title: String { scenario.title }
    public var symbol: String { scenario.symbol }
}

/// 技能目录：内置 +（预留）外部文档合并入口。
public struct AgentSkillCatalog: Sendable {
    public let skills: [AgentSkill]

    public init(skills: [AgentSkill]) {
        var seen = Set<String>()
        var ordered: [AgentSkill] = []
        for s in skills {
            if seen.insert(s.id).inserted {
                ordered.append(s)
            }
        }
        self.skills = ordered
    }

    public static func bundled() throws -> AgentSkillCatalog {
        AgentSkillCatalog(skills: try AgentBundledSkills.all())
    }

    /// 解析失败时回空目录，但 Debug 断言 + 打印，避免静默丢光全部技能。
    public static var bundledOrEmpty: AgentSkillCatalog {
        do {
            return try bundled()
        } catch {
            #if DEBUG
            print("AgentSkillCatalog: bundled skills failed to parse: \(error)")
            assertionFailure("AgentSkillCatalog.bundled() failed: \(error)")
            #endif
            return AgentSkillCatalog(skills: [])
        }
    }

    /// 内置 + 用户自定义文档合并：内置在前（id 冲突时内置优先，自定义无法覆盖内置），
    /// 自定义文档解析失败则跳过。自定义模板同构地进入目录，可被选中/生成/收藏。
    public static func merging(customDocuments: [String]) -> AgentSkillCatalog {
        var skills: [AgentSkill] = (try? AgentBundledSkills.all()) ?? []
        for raw in customDocuments {
            if let s = try? AgentSkillDocument.parse(raw) {
                skills.append(s)
            }
        }
        return AgentSkillCatalog(skills: skills)
    }

    public func skill(id: String) -> AgentSkill? {
        skills.first { $0.id == id }
    }

    /// 按**产出形态**（groupId）聚合。保留历史用途。
    public var groups: [AgentSkillGroup] {
        var order: [String] = []
        var map: [String: (title: String, items: [AgentSkill])] = [:]
        for s in skills {
            if map[s.groupId] == nil {
                order.append(s.groupId)
                map[s.groupId] = (s.groupTitle, [])
            }
            map[s.groupId]?.items.append(s)
        }
        return order.compactMap { gid in
            guard let g = map[gid] else { return nil }
            return AgentSkillGroup(id: gid, title: g.title, skills: g.items)
        }
    }

    /// 按**场景域**聚合，按 `TemplateScenario.allCases` 规范序排列，仅返回有模板的场景。
    public var scenarioGroups: [AgentScenarioGroup] {
        TemplateScenario.allCases.compactMap { scenario in
            let items = skills.filter { $0.scenario == scenario }
            return items.isEmpty ? nil : AgentScenarioGroup(scenario: scenario, skills: items)
        }
    }
}
