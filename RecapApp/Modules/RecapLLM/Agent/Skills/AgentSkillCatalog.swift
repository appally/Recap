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
            print("AgentSkillCatalog: bundled skills failed to parse: \(error)")
            assertionFailure("AgentSkillCatalog.bundled() failed: \(error)")
            return AgentSkillCatalog(skills: [])
        }
    }

    public func skill(id: String) -> AgentSkill? {
        skills.first { $0.id == id }
    }

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
}
