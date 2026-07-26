import Foundation
import RecapModels

public enum SearchWebError: LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case emptyQuery
    case apiMessage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "联网搜索返回无法解析。"
        case .httpStatus(let code):
            return "联网搜索失败（HTTP \(code)）。"
        case .emptyQuery:
            return "搜索内容为空。"
        case .apiMessage(let msg):
            return "联网搜索失败：\(msg)"
        }
    }
}

/// AnySearch 联网检索（JSON-RPC `tools/call` → `search`）。
/// Key 仅从 Keychain 读取；未配置时走匿名额度（较低限流）。
public enum SearchWebTool {
    private static let endpoint = URL(string: "https://api.anysearch.com/mcp")!

    public static func search(query: String, maxResults: Int = 3) async throws -> [WebHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw SearchWebError.emptyQuery }

        let capped = min(max(maxResults, 1), 10)
        let apiKey = KeychainStore.get(ToolPresets.anySearchKeychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "search",
                "arguments": [
                    "query": q,
                    "max_results": capped
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SearchWebError.httpStatus(status)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchWebError.invalidResponse
        }
        if let error = json["error"] as? [String: Any] {
            let msg = (error["message"] as? String) ?? "未知错误"
            throw SearchWebError.apiMessage(msg)
        }

        guard let result = json["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]] else {
            throw SearchWebError.invalidResponse
        }

        let markdown = content
            .compactMap { item -> String? in
                guard (item["type"] as? String) == "text" else { return nil }
                return item["text"] as? String
            }
            .joined(separator: "\n")

        // 解析失败返回空：不合成假命中污染引用与模型上下文
        return parseSearchMarkdown(markdown, limit: capped)
    }

    /// 解析 AnySearch 返回的 Markdown 结果块。
    public static func parseSearchMarkdown(_ markdown: String, limit: Int = 3) -> [WebHit] {
        let pattern = #"###\s+\d+\.\s+(.+?)\n-\s+\*\*URL\*\*:\s+(\S+)\n([\s\S]*?)(?=\n###\s+\d+\.|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let ns = markdown as NSString
        let matches = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: ns.length))
        var hits: [WebHit] = []
        for match in matches.prefix(limit) {
            guard match.numberOfRanges >= 4,
                  let titleRange = Range(match.range(at: 1), in: markdown),
                  let urlRange = Range(match.range(at: 2), in: markdown),
                  let bodyRange = Range(match.range(at: 3), in: markdown) else { continue }

            let title = String(markdown[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = String(markdown[urlRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            var body = String(markdown[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("- ") { body = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            // 去掉 markdown 标题符号噪音，压缩空白
            body = body
                .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            let snippet = String(body.prefix(500))
            guard !url.isEmpty else { continue }
            hits.append(WebHit(
                title: title.isEmpty ? url : title,
                url: url,
                content: snippet.isEmpty ? title : snippet
            ))
        }
        return hits
    }
}
