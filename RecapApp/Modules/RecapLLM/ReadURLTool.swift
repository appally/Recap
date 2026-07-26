import Foundation
import RecapModels

public struct ReadURLResult: Sendable, Equatable {
    public let url: URL
    public let text: String
    public let truncated: Bool

    public init(url: URL, text: String, truncated: Bool) {
        self.url = url
        self.text = text
        self.truncated = truncated
    }
}

public enum ReadURLError: LocalizedError, Sendable {
    case disallowedURL
    case emptyURL
    case httpStatus(Int)
    case emptyBody
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .disallowedURL: return "不允许读取该 URL（仅支持公网 http/https）。"
        case .emptyURL: return "URL 为空。"
        case .httpStatus(let c): return "读取网页失败（HTTP \(c)）。"
        case .emptyBody: return "网页正文为空。"
        case .network(let m): return "读取网页失败：\(m)"
        }
    }
}

/// Jina Reader 纯文本抓取：`https://r.jina.ai/<url>`。
public enum ReadURLTool {
    public static let jinaPrefix = "https://r.jina.ai/"

    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return false
        }
        if host.hasPrefix("127.") { return false }
        if isPrivateIPv4(host) { return false }
        if host.hasPrefix("169.254.") { return false }
        return true
    }

    public static func normalize(_ raw: String, maxChars: Int) -> String {
        let capped = max(maxChars, 1)
        var lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                if line.isEmpty { return true }
                let lower = line.lowercased()
                if lower.hasPrefix("skip to ") { return false }
                if lower == "menu" || lower == "navigation" { return false }
                return true
            }

        // 压缩连续空行
        var compacted: [String] = []
        var blank = false
        for line in lines {
            if line.isEmpty {
                if !blank {
                    compacted.append("")
                    blank = true
                }
            } else {
                compacted.append(line)
                blank = false
            }
        }
        var text = compacted.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > capped {
            let idx = text.index(text.startIndex, offsetBy: capped)
            let head = String(text[..<idx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            text = head + "\n\n…（已截断，共超出 \(capped) 字上限）"
        }
        return text
    }

    public static func fetchText(_ url: URL, maxChars: Int) async throws -> ReadURLResult {
        guard isAllowed(url) else { throw ReadURLError.disallowedURL }
        let absolute = url.absoluteString
        guard !absolute.isEmpty else { throw ReadURLError.emptyURL }

        guard let proxy = URL(string: jinaPrefix + absolute) else {
            throw ReadURLError.disallowedURL
        }

        var request = URLRequest(url: proxy)
        request.httpMethod = "GET"
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        if let key = KeychainStore.get(ToolPresets.jinaKeychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ReadURLError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ReadURLError.httpStatus(status)
        }
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            throw ReadURLError.emptyBody
        }
        let normalized = normalize(raw, maxChars: maxChars)
        let truncated = normalized.contains("…（已截断")
        return ReadURLResult(url: url, text: normalized, truncated: truncated)
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }
}
