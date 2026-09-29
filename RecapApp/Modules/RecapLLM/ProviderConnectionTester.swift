import Foundation
import RecapModels

/// 端点连接测试结果（plan 059 Wave B）。
public struct ConnectionTestOutcome: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case ok(latencyMs: Int)
        case authFailed
        case modelNotFound
        case timeout
        case badURL
        case httpError(Int)
        case unreachable(String)
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public var message: String {
        switch kind {
        case .ok(let ms):
            return "连接成功 · 首响应 \(ms)ms"
        case .authFailed:
            return "端点可达，但 API Key 无效（401/403）"
        case .modelNotFound:
            return "端点可达，但模型名不存在（404）——请核对该厂商当前模型 ID"
        case .timeout:
            return "超时（12s）——端点不可达或网络受限"
        case .badURL:
            return "Base URL 无效——须以 http(s) 开头"
        case .httpError(let code):
            return "HTTP \(code)——请查看该服务商文档"
        case .unreachable(let detail):
            return "无法连接：\(detail)"
        }
    }

    public var isOK: Bool {
        if case .ok = kind { return true }
        return false
    }
}

/// 一键连接测试（plan 059）：发一条 max_tokens=1 的非流式补全，翻译常见失败。
/// 刻意不做 thinking/tool_choice 自动探测（拒单维持）——那是发布前手动 smoke 的事。
public enum ProviderConnectionTester {

    public static func test(
        baseURL: String,
        apiKey: String,
        model: String,
        timeout: TimeInterval = 12
    ) async -> ConnectionTestOutcome {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http") else { return .init(kind: .badURL) }
        let urlText = trimmed.hasSuffix("/") ? trimmed + "chat/completions" : trimmed + "/chat/completions"
        guard let url = URL(string: urlText) else { return .init(kind: .badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1,
        ])

        let started = Date()
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = resp as? HTTPURLResponse else {
                return .init(kind: .unreachable("非 HTTP 响应"))
            }
            switch http.statusCode {
            case 200...299: return .init(kind: .ok(latencyMs: ms))
            case 401, 403: return .init(kind: .authFailed)
            case 404: return .init(kind: .modelNotFound)
            default: return .init(kind: .httpError(http.statusCode))
            }
        } catch let urlError as URLError where urlError.code == .timedOut {
            return .init(kind: .timeout)
        } catch {
            return .init(kind: .unreachable(error.localizedDescription))
        }
    }
}
