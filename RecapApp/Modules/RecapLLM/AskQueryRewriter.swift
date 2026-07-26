import Foundation

/// 代码侧查询改写（非 AgentLoop）：0 hit 时用 flash 产出检索词，再搜一次。
public enum AskQueryRewriter {
    public static let system = """
    你是会议检索查询改写器。根据用户问题输出最多 3 个适合在转写里子串检索的关键词/短语。
    只输出一行，英文逗号分隔，不要解释，不要标点句号。
    """

    public static func parseKeywords(_ raw: String) -> [String] {
        let normalized = raw
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "；", with: ",")
        var seen = Set<String>()
        var result: [String] = []
        let parts = normalized
            .components(separatedBy: CharacterSet(charactersIn: ",\n\t "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for part in parts {
            let clipped = String(part.prefix(20))
            guard clipped.count >= 2 else { continue }
            let key = clipped.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(clipped)
            if result.count >= 3 { break }
        }
        return result
    }

    public static func shouldRewrite(
        intent: AskQueryIntent,
        localHitCount: Int
    ) -> Bool {
        intent == .keywordSearch && localHitCount == 0
    }
}
