import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Pro 会员「凭证签发器」客户端
//   后端(Cloudflare Workers)只签发 60s–30min 的阿里临时 token;客户端缓存 + 滚动续签。
//   不碰用户音频:客户端拿 token 直连阿里 wss / LLM(与 BYOK 路径同构)。
//   双接口:current()(同步读缓存,供 makeCurrent / prepare 等同步路径) + ensureFresh()(异步换 token)
// ─────────────────────────────────────────────────────────────────────────────

public struct RecapIssuedCredential: Sendable, Equatable {
    public let token: String
    public let asrWSS: String
    public let llmBase: String
    public let remainingSeconds: Int?
}

public enum RecapCredentialError: Error, LocalizedError, Sendable {
    case notReady
    case notPro
    case issueFailed(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .notReady: return "Recap 云凭证尚未就绪(正在准备…)"
        case .notPro: return "当前非 Pro,Recap 会员模式不可用"
        case .issueFailed(let s, _): return "Recap 云凭证签发失败(HTTP \(s))"
        }
    }
}

/// Pro 会员模式下的阿里短期凭证提供者(@unchecked Sendable + NSLock)。
public final class RecapCredentialProvider: @unchecked Sendable {
    public static let shared = RecapCredentialProvider()

    private struct Cached {
        let token: String
        let asrWSS: String
        let llmBase: String
        let remainingSeconds: Int?
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var cached: Cached?
    private var ongoingFetch: Task<Cached, Error>?
    private var refreshTask: Task<Void, Never>?
    /// Sign-in-with-Apple 注入的 identityToken,下次 issue 随请求带上网关验签升级(验后即清)。
    private var pendingIdentityToken: String?

    /// 提前续签阈值:剩余 < 5min 即续。
    private let refreshLeadSeconds: TimeInterval = 300
    /// 缓存最低可用阈值:剩余 < 60s 视为过期(同步读取不再返回)。
    private let minValidSeconds: TimeInterval = 60

    public init() {}

    // MARK: - 端点

    /// 后端 /v1/issue 基址。用户在设置覆盖;默认占位上线前替换为备案子域。
    public static var endpoint: URL {
        if let raw = UserDefaults.standard.string(forKey: "recap.cloud.endpoint"),
           let url = URL(string: raw) {
            return url
        }
        // 已部署:Recap 凭证签发器(Cloudflare Worker,绑 recap.manymind.chat)
        return URL(string: "https://recap.manymind.chat")!
    }

    // MARK: - 读取 / 换取

    /// 同步读缓存(LLMProviderFactory / FunASREngine.prepare 等同步路径用)。
    /// 缓存有效返回;否则抛 notReady(调用方应在启动入口先 ensureFresh)。
    public func current() throws -> RecapIssuedCredential {
        guard isActiveCloud else { throw RecapCredentialError.notPro }
        guard let c = readCache(), c.expiresAt.timeIntervalSinceNow > minValidSeconds else {
            throw RecapCredentialError.notReady
        }
        return RecapIssuedCredential(token: c.token, asrWSS: c.asrWSS, llmBase: c.llmBase, remainingSeconds: c.remainingSeconds)
    }

    /// 异步换 token(启动 / 兜底续签)。并发去重,缓存够新则跳过。
    public func ensureFresh(force: Bool = false) async throws {
        guard isActiveCloud else { throw RecapCredentialError.notPro }
        if !force, let c = readCache(), c.expiresAt.timeIntervalSinceNow > refreshLeadSeconds { return }
        // 并发去重:复用进行中的请求
        if let ongoing = takeOngoingFetch() {
            _ = try await ongoing.value
            return
        }
        let elevationToken = takePendingIdentityToken()
        let task = Task { try await Self.fetchIssue(identityToken: elevationToken) }
        setOngoingFetch(task)
        defer { setOngoingFetch(nil) }
        let fetched = try await task.value
        writeCache(fetched)
    }

    /// 启动后台滚动续签(recapCloud + Pro 时在 app 启动调用)。
    public func startBackgroundRefresh() {
        guard isActiveCloud else { return }
        cancelBackgroundRefresh()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.ensureFresh()
                } catch {
                    // 续签失败:短等重试(旧 token 可能仍在有效期,不中断)
                    try? await Task.sleep(for: .seconds(15))
                    continue
                }
                // 睡到「过期前 refreshLeadSeconds」;最长 5min 醒一次兜底
                let remaining = self.readCache()?.expiresAt.timeIntervalSinceNow ?? 60
                let sleepFor = min(max(remaining - self.refreshLeadSeconds, 60), 300)
                try? await Task.sleep(for: .seconds(sleepFor))
            }
        }
        setRefreshTask(task)
    }

    public func cancelBackgroundRefresh() {
        takeRefreshTask()?.cancel()
    }

    /// 是否走托管凭证：Pro 会员(recapCloud + pro) 或 免费档(freeTrial)。
    private var isActiveCloud: Bool {
        (AIServiceMode.current == .recapCloud && RecapAccountStore.current.tier == .pro)
            || AIServiceMode.current == .freeTrial
    }

    // MARK: - 网络

    private static func fetchIssue(identityToken: String?) async throws -> Cached {
        var req = URLRequest(url: endpoint.appendingPathComponent("v1/issue"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        // 身份头(三档互斥):Pro=交易id / 免费档=设备ID(+签名升级时附 identityToken)。
        switch AIServiceMode.current {
        case .recapCloud:
            if let txn = RecapAccountStore.appleTransactionID {
                req.setValue(txn, forHTTPHeaderField: "X-Apple-Transaction-Id")
            }
        case .freeTrial:
            req.setValue(RecapAccountStore.deviceID, forHTTPHeaderField: "X-Recap-Device")
            if let jwt = identityToken {
                req.setValue(jwt, forHTTPHeaderField: "X-Apple-Identity-Token")
            }
        case .byok:
            break
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw RecapCredentialError.issueFailed(status: -1, body: error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw RecapCredentialError.issueFailed(status: -1, body: "no-http-response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RecapCredentialError.issueFailed(status: http.statusCode, body: body)
        }
        let decoded = try JSONDecoder().decode(IssueResponse.self, from: data)
        return Cached(
            token: decoded.dashscope_token,
            asrWSS: decoded.asr_wss,
            llmBase: decoded.llm_base,
            remainingSeconds: decoded.remaining_seconds,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        )
    }

    private struct IssueResponse: Decodable {
        let dashscope_token: String
        let expires_in: Int
        let asr_wss: String
        let llm_base: String
        let remaining_seconds: Int?
    }

    // MARK: - 锁保护的缓存 / 任务读写

    private func readCache() -> Cached? { lock.lock(); defer { lock.unlock() }; return cached }
    private func writeCache(_ c: Cached) { lock.lock(); defer { lock.unlock() }; cached = c }
    private func takeOngoingFetch() -> Task<Cached, Error>? { lock.lock(); defer { lock.unlock() }; return ongoingFetch }
    private func setOngoingFetch(_ t: Task<Cached, Error>?) { lock.lock(); defer { lock.unlock() }; ongoingFetch = t }
    private func takeRefreshTask() -> Task<Void, Never>? { lock.lock(); defer { lock.unlock() }; let t = refreshTask; refreshTask = nil; return t }
    private func setRefreshTask(_ t: Task<Void, Never>?) { lock.lock(); defer { lock.unlock() }; refreshTask = t }

    /// Sign-in-with-Apple 后注入 identityToken,下次 issue 随请求带上网关验签升级(验后即清)。
    public func setIdentityTokenForElevation(_ jwt: String) {
        lock.lock(); defer { lock.unlock() }
        pendingIdentityToken = jwt
    }
    private func takePendingIdentityToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        let t = pendingIdentityToken
        pendingIdentityToken = nil
        return t
    }
}
