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
    /// 服务端统一下发的 ASR 模型(默认 fun-asr-realtime)。FunASREngine 用此替代硬编码常量。
    public let asrModel: String
    /// 服务端统一下发的 LLM 模型(默认 qwen-plus)。LLMProviderFactory 用此替代模板硬编码。
    public let llmModel: String
}

public enum RecapCredentialError: Error, LocalizedError, Sendable {
    case notReady
    case notPro
    case issueFailed(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .notReady: return "云凭证尚未就绪（正在准备…）"
        case .notPro: return "当前非 Pro，会员模式不可用"
        case .issueFailed(let s, _): return "云凭证签发失败（HTTP \(s)）"
        }
    }

    /// 面向用户的签发失败文案:解析网关 403 body 区分「验证/订阅问题」与「额度耗尽」,
    /// 并按当前 tier 兜底(防御 body 解析失败),消除「Pro 用户看到免费额度已用完」的误导。
    /// - requires_membership:网关 Apple 验证未通过(订阅失效 / STOREKIT_HOST / .p8 问题)。
    /// - quota_exceeded:月度云端额度(Pro 计 token 时长 / 免费档按次)用尽。
    public var userMessage: String {
        switch self {
        case .notReady:
            return "云凭证尚未就绪，请稍后重试。"
        case .notPro:
            return "当前非 Pro，会员模式不可用。"
        case let .issueFailed(status, body):
            guard status == 403 else {
                return "凭证准备失败，请检查网络后重试。"
            }
            // 网关 403 body 形如 {"error":"requires_membership"} / {"error":"quota_exceeded"}
            let tier = RecapAccountStore.current.tier
            if body.contains("quota_exceeded") {
                return tier == .pro
                    ? "本月云端额度已用完。"
                    : "免费额度已用完，升级 Pro 或解锁自备密钥后再试。"
            }
            if body.contains("requires_membership") {
                return "Pro 凭证签发被拒，请确认订阅有效后重试。"
            }
            // body 解析失败的兜底:按 tier 区分,避免 Pro 用户看到「免费额度已用完」
            return tier == .pro
                ? "Pro 凭证签发被拒，请确认订阅有效后重试。"
                : "免费额度已用完，升级 Pro 或解锁自备密钥后再试。"
        }
    }
}

/// 凭证签发用途:服务端按此分桶计量(免费档 ASR 独立月度桶,与 LLM 隔离,成本可控)。
public enum IssueUsage: String, Sendable {
    case llm
    case asr
}

/// Pro 会员模式下的阿里短期凭证提供者(@unchecked Sendable + NSLock)。
public final class RecapCredentialProvider: @unchecked Sendable {
    public static let shared = RecapCredentialProvider()

    private struct Cached {
        let token: String
        let asrWSS: String
        let llmBase: String
        let remainingSeconds: Int?
        let asrModel: String
        let llmModel: String
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
        #if DEBUG
        // Debug 允许通过 UserDefaults 覆盖(便于本机 mock/staging 联调);Release 强制走生产域。
        if let raw = UserDefaults.standard.string(forKey: "recap.cloud.endpoint"),
           let url = URL(string: raw) {
            return url
        }
        #endif
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
        return RecapIssuedCredential(token: c.token, asrWSS: c.asrWSS, llmBase: c.llmBase, remainingSeconds: c.remainingSeconds, asrModel: c.asrModel, llmModel: c.llmModel)
    }

    /// 异步换 token(启动 / 兜底续签)。并发去重,缓存够新则跳过。
    public func ensureFresh(force: Bool = false, usage: IssueUsage = .llm) async throws {
        guard isActiveCloud else { throw RecapCredentialError.notPro }
        if !force, let c = readCache(), c.expiresAt.timeIntervalSinceNow > refreshLeadSeconds { return }
        // 并发去重(原子占坑):单次锁内「检查进行中请求,否则占坑新建」,
        // 杜绝两个调用者同时通过 nil 检查各自发 /v1/issue(重复签发 + 配额误计 + defer 互抹)。
        let task: Task<Cached, Error>
        switch claimOngoingFetch(usage: usage) {
        case .reuse(let ongoing):
            _ = try await ongoing.value
            return
        case .claimed(let created):
            task = created
        }
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
    public var isActiveCloud: Bool {
        (AIServiceMode.current == .recapCloud && RecapAccountStore.current.tier == .pro)
            || AIServiceMode.current == .freeTrial
    }

    // MARK: - 网络

    private static func fetchIssue(identityToken: String?, usage: IssueUsage = .llm) async throws -> Cached {
        var req = URLRequest(url: endpoint.appendingPathComponent("v1/issue"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 用途分桶:服务端据此把免费档 ASR 扣进独立月度桶(与 LLM 隔离)。
        req.setValue(usage.rawValue, forHTTPHeaderField: "X-Recap-Usage")
        req.timeoutInterval = 15
        // 身份头(三档互斥):Pro=交易id / 免费档=设备ID(+签名升级时附 identityToken)。
        // 深层防御:tier=Pro 但 mode 漂移到 freeTrial(双键独立持久化,见 MembershipStore.refreshEntitlements),
        // 强制按 Pro 走 recapCloud 签发(带 X-Apple-Transaction-Id),避免 Pro 用户被误路由进免费桶
        // 触发「免费额度已用完」。上游已双向同步修正,此处兜底冷启动竞态/旧版本残留。
        let effectiveMode: AIServiceMode =
            (RecapAccountStore.current.tier == .pro && AIServiceMode.current == .freeTrial)
                ? .recapCloud : AIServiceMode.current
        switch effectiveMode {
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
            asrModel: decoded.asr_model ?? ASRPresets.funRealtimeModel,
            llmModel: decoded.llm_model ?? "qwen-plus",
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        )
    }

    private struct IssueResponse: Decodable {
        let dashscope_token: String
        let expires_in: Int
        let asr_wss: String
        let llm_base: String
        let remaining_seconds: Int?
        let asr_model: String?
        let llm_model: String?
    }

    // MARK: - 锁保护的缓存 / 任务读写

    private func readCache() -> Cached? { lock.lock(); defer { lock.unlock() }; return cached }
    private func writeCache(_ c: Cached) {
        lock.lock(); defer { lock.unlock() }
        cached = c
        // 免费档:用网关返回的 remaining_seconds 锚定本地滴灌计数(权威,纠正漂移/跨设备)。
        if AIServiceMode.current == .freeTrial, let rem = c.remainingSeconds {
            FreeTrialQuota.syncFromServerSeconds(rem)
        }
    }
    /// 原子「检查进行中请求,否则占坑新建」。单次锁内完成,杜绝并发重复签发。
    private enum OngoingClaim {
        case reuse(Task<Cached, Error>)
        case claimed(Task<Cached, Error>)
    }
    private func claimOngoingFetch(usage: IssueUsage) -> OngoingClaim {
        lock.lock(); defer { lock.unlock() }
        if let ongoing = ongoingFetch { return .reuse(ongoing) }
        // 占坑:取走 pendingIdentityToken(验签升级用,验后即清),建 Task 并登记
        let elevationToken = pendingIdentityToken
        pendingIdentityToken = nil
        let task = Task { try await Self.fetchIssue(identityToken: elevationToken, usage: usage) }
        ongoingFetch = task
        return .claimed(task)
    }
    private func setOngoingFetch(_ t: Task<Cached, Error>?) { lock.lock(); defer { lock.unlock() }; ongoingFetch = t }
    private func takeRefreshTask() -> Task<Void, Never>? { lock.lock(); defer { lock.unlock() }; let t = refreshTask; refreshTask = nil; return t }
    private func setRefreshTask(_ t: Task<Void, Never>?) { lock.lock(); defer { lock.unlock() }; refreshTask = t }

    /// Sign-in-with-Apple 后注入 identityToken,下次 issue 随请求带上网关验签升级(验后即清)。
    public func setIdentityTokenForElevation(_ jwt: String) {
        lock.lock(); defer { lock.unlock() }
        pendingIdentityToken = jwt
    }
}
