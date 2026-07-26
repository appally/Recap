import Foundation

/// 联网搜索词净化与拼装（W2）：避免把口语/追问前缀原样丢给 AnySearch。
public enum AskWebQueryBuilder {
    public static let maxQueryChars = 80

    private static let conversationalPrefixes = [
        "基于你上一条回答，",
        "基于你上一条回答",
        "继续：",
        "继续:",
    ]

    /// 去掉追问前缀与多余空白。
    public static func sanitizeConversational(_ query: String) -> String {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in conversationalPrefixes {
            if q.hasPrefix(prefix) {
                q = String(q.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        q = q.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(q.prefix(maxQueryChars))
    }

    /// 优先用模型改写行；否则用净化后的原问。
    public static func buildSearchQuery(raw: String, rewrittenLine: String?) -> String {
        if let line = parseWebQueryLine(rewrittenLine ?? ""), !line.isEmpty {
            return line
        }
        let sanitized = sanitizeConversational(raw)
        return sanitized.isEmpty ? String(raw.prefix(maxQueryChars)) : sanitized
    }

    /// 取改写结果第一行，长度 2...maxQueryChars。
    public static func parseWebQueryLine(_ raw: String) -> String? {
        let first = raw
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard var line = first else { return nil }
        if (line.hasPrefix("\"") && line.hasSuffix("\""))
            || (line.hasPrefix("「") && line.hasSuffix("」"))
            || (line.hasPrefix("'") && line.hasSuffix("'")) {
            line = String(line.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        line = String(line.prefix(maxQueryChars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count >= 2 else { return nil }
        return line
    }
}

extension AskQueryRewriter {
    /// 互联网搜索专用改写（与本地转写检索 system 分离）。
    public static let webSystem = """
    你是互联网搜索查询改写器。将用户问题改写成适合搜索引擎的短查询。
    去掉口语、追问前缀、会议指代（刚才/那个/上面）。保留专有名词与关键实体。
    只输出一行，空格分隔，不要标点句号，不要解释。
    """
}
