import Foundation

public enum AgentSkillDocumentError: LocalizedError, Equatable {
    case missingFrontMatter
    case missingRequiredKey(String)
    case emptyBody
    case invalidMaxSteps

    public var errorDescription: String? {
        switch self {
        case .missingFrontMatter: return "SKILL.md 缺少 --- frontmatter ---"
        case .missingRequiredKey(let k): return "SKILL.md 缺少必填字段：\(k)"
        case .emptyBody: return "SKILL.md body（system prompt）为空"
        case .invalidMaxSteps: return "maxSteps 无效"
        }
    }
}

/// 解析 SKILL.md（简易 frontmatter，无第三方 YAML）。
public enum AgentSkillDocument {
    public static let defaultAllowedTools: Set<String> = [
        "search_transcript",
        "search_brief",
        "list_action_items",
    ]

    /// 写操作与递归入口，内置 skill 与嵌套执行均禁止。
    public static let forbiddenTools: Set<String> = [
        "create_reminders",
        "revise_minutes",
        "run_skill",
    ]

    public static func parse(_ raw: String) throws -> AgentSkill {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else {
            throw AgentSkillDocumentError.missingFrontMatter
        }
        let afterOpen = normalized.dropFirst(3)
        guard let endRange = afterOpen.range(of: "\n---") else {
            throw AgentSkillDocumentError.missingFrontMatter
        }
        let fmBlock = String(afterOpen[..<endRange.lowerBound])
        var body = String(afterOpen[endRange.upperBound...])
        if body.hasPrefix("\n") { body = String(body.dropFirst()) }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw AgentSkillDocumentError.emptyBody }

        let meta = parseFrontMatter(fmBlock)
        func require(_ key: String) throws -> String {
            guard let v = meta[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
                throw AgentSkillDocumentError.missingRequiredKey(key)
            }
            return v
        }

        let id = try require("id")
        let name = try require("name")
        let description = try require("description")
        let icon = meta["icon"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "wand.and.stars"
        let groupId = meta["group"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "general"
        let groupTitle = meta["groupTitle"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? groupId
        let role = parseRole(meta["modelRole"])
        let maxSteps = parseMaxSteps(meta["maxSteps"])
        var tools = parseTools(meta["allowedTools"])
        tools.subtract(forbiddenTools)
        if tools.isEmpty { tools = defaultAllowedTools }

        return AgentSkill(
            id: id,
            name: name,
            description: description,
            icon: icon,
            groupId: groupId,
            groupTitle: groupTitle,
            systemPrompt: body,
            allowedTools: tools,
            modelRole: role,
            maxSteps: maxSteps
        )
    }

    /// 供测试：把 skill 再编码成 SKILL.md 文本。
    public static func encode(_ skill: AgentSkill) -> String {
        let tools = skill.allowedTools.sorted().joined(separator: ", ")
        let role: String = {
            switch skill.modelRole {
            case .quick: return "quick"
            case .deep: return "deep"
            }
        }()
        return """
        ---
        id: \(skill.id)
        name: \(skill.name)
        description: \(skill.description)
        icon: \(skill.icon)
        group: \(skill.groupId)
        groupTitle: \(skill.groupTitle)
        modelRole: \(role)
        maxSteps: \(skill.maxSteps)
        allowedTools: \(tools)
        ---

        \(skill.systemPrompt)
        """
    }

    // MARK: - Private

    private static func parseFrontMatter(_ block: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in block.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            map[key] = value
        }
        return map
    }

    private static func parseRole(_ raw: String?) -> AgentModelRole {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "deep", "pro": return .deep
        default: return .quick // quick / flash / nil
        }
    }

    private static func parseMaxSteps(_ raw: String?) -> Int {
        guard let raw, let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 3
        }
        return min(max(n, 1), 6)
    }

    private static func parseTools(_ raw: String?) -> Set<String> {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultAllowedTools
        }
        let parts = raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(parts)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
