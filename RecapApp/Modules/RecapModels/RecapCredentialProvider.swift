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
    /// 服务端统一下发的 LLM 模型(网关 LLM_MODEL,现 qwen-plus);缺省回落 LLMPresets.cloudDefaultModel。
    public let llmModel: String
    /// token 本身的过期时刻（≠ remainingSeconds——那是网关配额桶剩余，非 token 寿命）。
    /// FunASREngine 的 LIVE 会话滚动续签据此排期（token 到期前主动换会话）。
    public let tokenExpiresAt: Date
    /// 全局共享热词表 id（网关 ASR_VOCABULARY_ID 下发；未配置为 nil）。
    /// paraformer 不支持 input.context，托管档热词走 run-task payload.vocabulary_id。
    public let asrVocabularyId: String?
}

public enum RecapCredentialError: Error, LocalizedError, Sendable {
    case notReady
    case notPro
    case issueFailed(status: Int, body: String)
    /// 本地存的 Apple 交易 ID 是合成/占位值（如 "0"）——典型来源：Xcode scheme 挂了
    /// Recap.storekit 配置时「购买」走本地 StoreKit 模拟，其交易在苹果服务器（含沙盒）不存在，
    /// 云端验证必然 403。提前拦截并给出准确文案，避免误导性的「请确认订阅有效」。
    case invalidLocalTransactionID(String)

    public var errorDescription: String? {
        switch self {
        case .notReady: return "云凭证尚未就绪（正在准备…）"
        case .notPro: return "当前非 Pro，会员模式不可用"
        case .issueFailed(let s, _): return "云凭证签发失败（HTTP \(s)）"
        case .invalidLocalTransactionID(let txn): return "Pro 交易凭证无效（本地测试数据 \(txn)）"
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
        case .invalidLocalTransactionID:
            return "Pro 交易凭证无效（来自 Xcode 本地 StoreKit 测试）。请改用本地网关联调，或在未挂 StoreKit 配置的 build 中用沙盒账号重新购买。"
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

    /// internal 供测试注入 fetchIssueFactory 构造成功凭证（生产仅由 fetchIssue 产出）。
    struct Cached {
        let token: String
        let asrWSS: String
        let llmBase: String
        let remainingSeconds: Int?
        let asrModel: String
        let llmModel: String
        let expiresAt: Date
        let asrVocabularyId: String?
        /// 签发时的语言（网关按 X-Recap-Lang 下发对应 asr_model）。缓存命中需语言一致——
        /// 英文会议的重转必须拿到英文模型 token，不能复用中文 token。
        let lang: MeetingLanguage
    }

    private let lock = NSLock()
    private var cached: Cached?
    private var ongoingFetch: Ongoing?
    private var refreshTask: Task<Void, Never>?
    /// Sign-in-with-Apple 注入的 identityToken,下次 issue 随请求带上网关验签升级(验后即清)。
    private var pendingIdentityToken: String?

    /// 提前续签阈值:剩余 < 5min 即续。
    private let refreshLeadSeconds: TimeInterval = 300
    /// 缓存最低可用阈值:剩余 < 60s 视为过期(同步读取不再返回)。
    private let minValidSeconds: TimeInterval = 60
    /// 续签失败退避:15s 起、指数翻倍、封顶 5min(断网时避免每 15s 唤醒耗电);成功即重置。
    private var retryBackoff: TimeInterval = 15
    private static let retryBackoffMax: TimeInterval = 300

    /// quota_exceeded 403 否定缓存条目：TTL 内对同 usage 直接重放拒绝（不发请求）。
    /// 消灭同一场会话内 LIVE 开场 → endLive 重转 → startProcessing 强刷的三连重复
    /// /v1/issue（每场白耗 1-2 次往返，最坏 15s/次的超时窗口），并保证文案稳定——
    /// 额度耗尽的状态不会因后续请求赶上网络抖动被改写成「请检查网络」。
    /// tier/mode 快照参与命中判定：购买升级（free→pro）/模式切换自失效，无需显式清除钩子。
    private struct NegativeEntry {
        let until: Date
        let status: Int
        let body: String
        let tier: MembershipTier
        let mode: AIServiceMode
    }

    /// 否定缓存按 usage 分桶（免费档 ASR/LLM 是两个独立月度桶，一侧耗尽不代表另一侧），
    /// usage 内不分语言（配额桶不分语言，zh 耗尽 en 必然同拒）。
    private var negativeEntries: [IssueUsage: NegativeEntry] = [:]
    /// 否定缓存 TTL：额度按月重置、购买即 tier 变更，5min 足够覆盖一场会话的三连问。
    private var negativeCacheTTLSeconds: TimeInterval = 300
    /// fetchIssue 工厂：默认直连网络；测试注入避免触网（锁内读写）。
    /// （存储属性默认值不能引用协变 Self，故显式写类名。）
    private var fetchIssueFactory: (_ identityToken: String?, _ usage: IssueUsage, _ lang: MeetingLanguage) async throws -> Cached =
        { try await RecapCredentialProvider.fetchIssue(identityToken: $0, usage: $1, lang: $2) }

    public init() {}

    // MARK: - 端点

    /// 后端 /v1/issue 基址。Debug 可经 UserDefaults 覆盖联调；Release 固定生产域。
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
    /// - Parameter lang: 请求的转写语言。ASR 消费方（`requiresASRModel: true`，默认）须语言
    ///   匹配才返回——asr_model 随语言变，英文重转不能误用 zh token。LLM 消费方传 false：
    ///   token/llm_model 与语言无关，复用本场已签的（任一语言）token 即可——单槽缓存按
    ///   lang 互逐，若 LLM 也校验语言，英文会议的纪要/润色会多签一次（免费档白扣 120s）。
    ///   不匹配或过期抛 notReady(调用方应在启动入口先 ensureFresh)。
    public func current(lang: MeetingLanguage = .zh, requiresASRModel: Bool = true) throws -> RecapIssuedCredential {
        guard isActiveCloud else { throw RecapCredentialError.notPro }
        let hit = requiresASRModel ? readCache(lang: lang) : readCacheAny()
        guard let c = hit, c.expiresAt.timeIntervalSinceNow > minValidSeconds else {
            throw RecapCredentialError.notReady
        }
        return RecapIssuedCredential(token: c.token, asrWSS: c.asrWSS, llmBase: c.llmBase, remainingSeconds: c.remainingSeconds, asrModel: c.asrModel, llmModel: c.llmModel, tokenExpiresAt: c.expiresAt, asrVocabularyId: c.asrVocabularyId)
    }

    /// 异步换 token(启动 / 兜底续签)。并发去重,缓存够新则跳过。
    /// quota_exceeded 否定缓存命中时直接重放 403（force 也不豁免——强刷为恢复瞬态,
    /// 额度耗尽是持久拒绝，重放省一次往返且文案与首次拒绝一致）。
    /// - Parameter lang: 请求的转写语言；网关据此签发对应 asr_model（zh=en 之外按 zh）。
    public func ensureFresh(force: Bool = false, usage: IssueUsage = .llm, lang: MeetingLanguage = .zh) async throws {
        guard isActiveCloud else { throw RecapCredentialError.notPro }
        if !force, let c = readCache(lang: lang), c.expiresAt.timeIntervalSinceNow > refreshLeadSeconds { return }
        if let replayed = takeNegativeEntryIfValid(usage: usage) {
            throw replayed
        }
        // 并发去重(原子占坑):单次锁内「检查进行中请求,否则占坑新建」,
        // 杜绝两个调用者同时通过 nil 检查各自发 /v1/issue(重复签发 + 配额误计 + defer 互抹)。
        let task: Task<Cached, Error>
        switch claimOngoingFetch(usage: usage, lang: lang) {
        case .reuse(let ongoing):
            _ = try await ongoing.value
            return
        case .claimed(let created):
            task = created
        }
        defer { setOngoingFetch(nil) }
        do {
            let fetched = try await task.value
            writeCache(fetched)
        } catch {
            // 仅缓存 quota_exceeded：requires_membership 可能是网关/Apple 验签的瞬时故障，
            // 5min 内把 Pro 用户锁死在「订阅无效」文案得不偿失；额度耗尽则是确定性持久态。
            if case let RecapCredentialError.issueFailed(status, body) = error,
               status == 403, body.contains("quota_exceeded") {
                writeNegativeEntry(
                    NegativeEntry(
                        until: Date().addingTimeInterval(negativeTTL()),
                        status: status,
                        body: body,
                        tier: RecapAccountStore.current.tier,
                        mode: AIServiceMode.current
                    ),
                    usage: usage)
            }
            throw error
        }
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
                    // 成功:重置退避(下次失败重新从 15s 起)
                    self.retryBackoff = 15
                } catch {
                    // 续签失败:指数退避后重试(旧 token 可能仍在有效期,不中断)。
                    // 断网/网关不可达时避免每 15s 唤醒,省电;上限 5min 兜底(与 refresh 周期同量级)。
                    try? await Task.sleep(for: .seconds(self.retryBackoff))
                    self.retryBackoff = min(self.retryBackoff * 2, Self.retryBackoffMax)
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

    private static func fetchIssue(identityToken: String?, usage: IssueUsage = .llm, lang: MeetingLanguage = .zh) async throws -> Cached {
        var req = URLRequest(url: endpoint.appendingPathComponent("v1/issue"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 用途分桶:服务端据此把免费档 ASR 扣进独立月度桶(与 LLM 隔离)。
        req.setValue(usage.rawValue, forHTTPHeaderField: "X-Recap-Usage")
        // 语言:服务端据此下发对应 asr_model(zh / en),英文会议重转必须匹配。
        req.setValue(lang.rawValue, forHTTPHeaderField: "X-Recap-Lang")
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
                // 卫生拦截：合成/占位交易 ID（本地 StoreKit 测试产物，如 "0"）发给网关只会
                // 换回误导性的「请确认订阅有效」。真 Apple 交易 ID 为 ≥10 位数字。
                guard txn.count >= 8, txn.allSatisfy(\.isNumber) else {
                    throw RecapCredentialError.invalidLocalTransactionID(txn)
                }
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
            (data, resp) = try await Self.loadDataWithTransientRetry(req)
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
            llmModel: decoded.llm_model ?? LLMPresets.cloudDefaultModel,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)),
            asrVocabularyId: decoded.asr_vocabulary_id,
            lang: lang
        )
    }

    /// 瞬时网络错误（本地代理/VPN 链路抖动，快速失败 <1s）短暂等待后重试一次。
    /// 签发是纪要/录音的关键路径，一次廉价重试可救回代理瞬断（2026-09-02 日志实测
    /// 127.0.0.1 代理 503/-1005 一抖即废整场纪要）。代价权衡：若首发的响应在网关已
    /// 签发后丢失，重试会多计一次免费档 LLM 桶（120s）——远小于纪要整体失败。
    /// `load` 参数仅测试注入。
    static func loadDataWithTransientRetry(
        _ req: URLRequest,
        load: (_ req: URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async throws -> (Data, URLResponse) {
        do {
            return try await load(req)
        } catch {
            guard isFastTransientNetworkError(error) else { throw error }
        }
        // 短间隔；期间被取消则第二发会立即以 cancelled 失败，不拖泥带水。
        try? await Task.sleep(nanoseconds: 800_000_000)
        return try await load(req)
    }

    /// 「快速失败的瞬时网络错误」指纹。刻意排除：
    /// - timedOut：15s 超时慢失败已卡满关键路径，重试再翻倍不可接受；
    /// - notConnectedToInternet：持久离线，重试无意义；
    /// - cancelled：调用方主动放弃。
    static func isFastTransientNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost,   // -1005：连接中断（bad MAC/代理断流）
             .cannotConnectToHost,  // -1004
             .cannotFindHost,          // -1003：代理 DNS 规则抖动
             .dnsLookupFailed:         // -1006
            return true
        default:
            return false
        }
    }

    /// 账号删除（App Store 5.1.1(v)）：identityToken 验签后由网关清空
    /// `apple:<sub>` 共享桶与本设备桶（身份标识+月度用量）。
    /// 需调用方现取新 identityToken（JWT ~10min 时效，不做持久化）。
    public enum RemoteDeleteOutcome {
        /// 服务端已清空。
        case deleted
        /// 网关明确拒绝（401/403）：验签失败或服务端配置错（如 APPLE_BUNDLE_ID 未注入）——
        /// 重试无意义，提示联系支持；本地登录态保留。
        case rejected
        /// 网络/超时/5xx：可重试，本地登录态保留。
        case networkFailure
    }

    @discardableResult
    public static func deleteAccountRemotely(identityToken: String) async -> RemoteDeleteOutcome {
        var req = URLRequest(url: endpoint.appendingPathComponent("v1/account/delete"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue(identityToken, forHTTPHeaderField: "X-Apple-Identity-Token")
        req.setValue(RecapAccountStore.deviceID, forHTTPHeaderField: "X-Recap-Device")
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else {
            return .networkFailure
        }
        switch http.statusCode {
        case 200: return .deleted
        case 401, 403: return .rejected
        default: return .networkFailure
        }
    }

    private struct IssueResponse: Decodable {
        let dashscope_token: String
        let expires_in: Int
        let asr_wss: String
        let llm_base: String
        let remaining_seconds: Int?
        let asr_model: String?
        let llm_model: String?
        /// 网关配置了 ASR_VOCABULARY_ID 才有此键（未配置/空串不带，双向兼容）。
        let asr_vocabulary_id: String?
    }

    // MARK: - 锁保护的缓存 / 任务读写

    private func readCache(lang: MeetingLanguage = .zh) -> Cached? {
        lock.lock(); defer { lock.unlock() }
        guard let cached, cached.lang == lang else { return nil }
        return cached
    }
    /// 不校验语言的缓存读取（LLM 消费方：token/llm_model 与语言无关）。
    private func readCacheAny() -> Cached? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }
    private func writeCache(_ c: Cached) {
        lock.lock(); defer { lock.unlock() }
        cached = c
        // 免费档:用网关返回的 remaining_seconds 锚定本地滴灌计数(权威,纠正漂移/跨设备)。
        if AIServiceMode.current == .freeTrial, let rem = c.remainingSeconds {
            FreeTrialQuota.syncFromServerSeconds(rem)
        }
    }
    /// 原子「检查进行中请求,否则占坑新建」。单次锁内完成,杜绝并发重复签发。
    /// 语言不一致的进行中请求不复用（zh 请求不应吞掉 en 请求的去重占坑）。
    private enum OngoingClaim {
        case reuse(Task<Cached, Error>)
        case claimed(Task<Cached, Error>)
    }
    private struct Ongoing {
        let lang: MeetingLanguage
        let task: Task<Cached, Error>
    }
    private func claimOngoingFetch(usage: IssueUsage, lang: MeetingLanguage) -> OngoingClaim {
        lock.lock(); defer { lock.unlock() }
        if let ongoing = ongoingFetch, ongoing.lang == lang { return .reuse(ongoing.task) }
        // 占坑:取走 pendingIdentityToken(验签升级用,验后即清),建 Task 并登记
        let elevationToken = pendingIdentityToken
        pendingIdentityToken = nil
        let factory = fetchIssueFactory
        let task = Task { try await factory(elevationToken, usage, lang) }
        ongoingFetch = Ongoing(lang: lang, task: task)
        return .claimed(task)
    }
    private func setOngoingFetch(_ t: Ongoing?) { lock.lock(); defer { lock.unlock() }; ongoingFetch = t }
    private func takeRefreshTask() -> Task<Void, Never>? { lock.lock(); defer { lock.unlock() }; let t = refreshTask; refreshTask = nil; return t }
    private func setRefreshTask(_ t: Task<Void, Never>?) { lock.lock(); defer { lock.unlock() }; refreshTask = t }

    // MARK: - quota_exceeded 否定缓存（锁保护）

    /// 命中且未过期（tier/mode 快照与当前一致）→ 返回重放错误；过期/失配顺带清除返回 nil。
    private func takeNegativeEntryIfValid(usage: IssueUsage) -> RecapCredentialError? {
        let tier = RecapAccountStore.current.tier
        let mode = AIServiceMode.current
        lock.lock(); defer { lock.unlock() }
        guard let e = negativeEntries[usage] else { return nil }
        guard e.tier == tier, e.mode == mode, Date() < e.until else {
            negativeEntries[usage] = nil
            return nil
        }
        return RecapCredentialError.issueFailed(status: e.status, body: e.body)
    }

    private func writeNegativeEntry(_ e: NegativeEntry, usage: IssueUsage) {
        lock.lock(); defer { lock.unlock() }
        negativeEntries[usage] = e
    }

    private func negativeTTL() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return negativeCacheTTLSeconds
    }

    // MARK: - 测试支持（@testable；生产勿用）

    /// 替换 /v1/issue 实现（避免测试触网）。锁内写，claimOngoingFetch 锁内读。
    func setFetchIssueFactoryForTesting(_ factory: @escaping (_ identityToken: String?, _ usage: IssueUsage, _ lang: MeetingLanguage) async throws -> Cached) {
        lock.lock(); defer { lock.unlock() }
        fetchIssueFactory = factory
    }

    /// 覆盖否定缓存 TTL（默认 300s），测过期/失效路径。
    func setNegativeCacheTTLForTesting(_ ttl: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        negativeCacheTTLSeconds = ttl
    }

    /// Sign-in-with-Apple 后注入 identityToken,下次 issue 随请求带上网关验签升级(验后即清)。
    public func setIdentityTokenForElevation(_ jwt: String) {
        lock.lock(); defer { lock.unlock() }
        pendingIdentityToken = jwt
    }
}
