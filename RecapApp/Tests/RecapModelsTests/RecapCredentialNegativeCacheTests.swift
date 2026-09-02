import XCTest
@testable import RecapModels

/// quota_exceeded 403 否定缓存回归（2026-09-02 日志诊断 P1）：
/// 同一场会话内 LIVE 开场 → endLive 重转 → startProcessing 强刷三连打 /v1/issue，
/// 且文案随「网络运气」在「免费额度已用完」与「请检查网络」间漂移。
/// 修复后：首个 403 缓存 5min，后续同 usage 调用（含 force）零往返重放同一拒绝。
final class RecapCredentialNegativeCacheTests: XCTestCase {

    /// 计数器（工厂闭包跑在任意 executor，勿用裸 var）。
    private final class Counter: @unchecked Sendable {
        private let l = NSLock()
        private var v = 0
        var count: Int { l.lock(); defer { l.unlock() }; return v }
        func increment() { l.lock(); defer { l.unlock() }; v += 1 }
    }

    // 每个测试方法独立的测试实例：内联 let 即为每测新建，闭包捕获无可选退化。
    private let provider = RecapCredentialProvider()
    private let fetchCount = Counter()
    private var savedMode: AIServiceMode = .freeTrial
    private var savedAccount: RecapAccount = .guest

    override func setUp() {
        super.setUp()
        savedMode = AIServiceMode.current
        savedAccount = RecapAccountStore.current
        AIServiceMode.current = .freeTrial
        RecapAccountStore.current = .guest
    }

    override func tearDown() {
        AIServiceMode.current = savedMode
        RecapAccountStore.current = savedAccount
        super.tearDown()
    }

    // MARK: - 辅助

    private func makeCached(lang: MeetingLanguage = .zh) -> RecapCredentialProvider.Cached {
        .init(token: "tok", asrWSS: "wss://example", llmBase: "https://example",
              remainingSeconds: 100, asrModel: "asr-m", llmModel: "llm-m",
              expiresAt: Date().addingTimeInterval(1800),
              asrVocabularyId: nil, lang: lang)
    }

    private func makeFactoryThrowQuota() {
        provider.setFetchIssueFactoryForTesting { [fetchCount] _, _, _ in
            fetchCount.increment()
            throw RecapCredentialError.issueFailed(status: 403, body: #"{"error":"quota_exceeded"}"#)
        }
    }

    /// 跑一次 ensureFresh 并捕获错误（nil = 成功）。
    private func run(usage: IssueUsage = .asr, lang: MeetingLanguage = .zh, force: Bool = true) async -> Error? {
        do {
            try await provider.ensureFresh(force: force, usage: usage, lang: lang)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - 核心：缓存 + 重放

    func testQuota403ReplayedWithoutRefetch() async {
        makeFactoryThrowQuota()
        guard case let RecapCredentialError.issueFailed(s1, b1)? = await run() else {
            return XCTFail("首次应抛 403")
        }
        XCTAssertEqual(s1, 403)
        XCTAssertTrue(b1.contains("quota_exceeded"), "body 应保留原始 403 内容")
        XCTAssertEqual(fetchCount.count, 1)

        // force 强刷（startProcessing 路径）也不豁免：TTL 内零往返重放同一拒绝。
        guard case let RecapCredentialError.issueFailed(s2, b2)? = await run() else {
            return XCTFail("第二次应重放 403")
        }
        XCTAssertEqual(s2, 403)
        XCTAssertEqual(b2, b1, "重放的 status/body 应与原拒绝一致（文案稳定）")
        XCTAssertEqual(fetchCount.count, 1, "否定缓存命中不得再发请求")

        // 重放错误的用户文案 = 真实额度耗尽（非「请检查网络」）。
        let replayed = RecapCredentialError.issueFailed(status: s2, body: b2)
        XCTAssertTrue(replayed.userMessage.contains("免费额度已用完"), "免费档应得到额度耗尽文案")
    }

    func testSuccessIssuesThenPositiveCacheSkipsRefetch() async {
        provider.setFetchIssueFactoryForTesting { [fetchCount] _, _, _ in
            fetchCount.increment()
            return self.makeCached()
        }
        let first = await run()
        XCTAssertNil(first)
        XCTAssertEqual(fetchCount.count, 1)
        // 非 force：正缓存足够新 → 早退，不打网络。
        let second = await run(force: false)
        XCTAssertNil(second)
        XCTAssertEqual(fetchCount.count, 1)
    }

    // MARK: - 边界：什么不缓存

    func testNegativeEntryUsageScoped() async {
        makeFactoryThrowQuota()
        _ = await run(usage: .asr)
        XCTAssertEqual(fetchCount.count, 1)
        // ASR 桶耗尽不代表 LLM 桶耗尽：.llm 照常打网络（此处也让其 403，验 fetch 被调用）。
        makeFactoryThrowQuota()
        _ = await run(usage: .llm)
        XCTAssertEqual(fetchCount.count, 2, "LLM usage 不应被 ASR 的否定缓存拦截")
    }

    func testNegativeEntryLangAgnosticWithinUsage() async {
        makeFactoryThrowQuota()
        _ = await run(usage: .asr, lang: .zh)
        XCTAssertEqual(fetchCount.count, 1)
        _ = await run(usage: .asr, lang: .en)
        XCTAssertEqual(fetchCount.count, 1, "配额桶不分语言：zh 的 403 应覆盖 en，不再发请求")
    }

    func testRequiresMembership403NotCached() async {
        provider.setFetchIssueFactoryForTesting { [fetchCount] _, _, _ in
            fetchCount.increment()
            throw RecapCredentialError.issueFailed(status: 403, body: #"{"error":"requires_membership"}"#)
        }
        _ = await run()
        _ = await run()
        XCTAssertEqual(fetchCount.count, 2, "requires_membership 可能是验签瞬时故障，不得缓存")
    }

    func testNetworkErrorNotCached() async {
        provider.setFetchIssueFactoryForTesting { [fetchCount] _, _, _ in
            fetchCount.increment()
            throw RecapCredentialError.issueFailed(status: -1, body: "网络连接已中断")
        }
        _ = await run()
        _ = await run()
        XCTAssertEqual(fetchCount.count, 2, "网络错误是瞬态，不得缓存")
    }

    // MARK: - 失效路径

    func testTierChangeInvalidatesEntry() async {
        makeFactoryThrowQuota()
        _ = await run()
        XCTAssertEqual(fetchCount.count, 1)
        // 购买升级：tier 快照失配 → 否定缓存自失效，恢复打网络（购买后立即生效）。
        var acc = RecapAccountStore.current
        acc.tier = .pro
        RecapAccountStore.current = acc
        makeFactoryThrowQuota()
        _ = await run()
        XCTAssertEqual(fetchCount.count, 2, "tier 变更后否定缓存应失效")
    }

    func testExpiryClearsEntry() async {
        provider.setNegativeCacheTTLForTesting(0.05)
        makeFactoryThrowQuota()
        _ = await run()
        XCTAssertEqual(fetchCount.count, 1)
        try? await Task.sleep(for: .milliseconds(150))
        provider.setFetchIssueFactoryForTesting { [fetchCount] _, _, _ in
            fetchCount.increment()
            return self.makeCached()
        }
        let after = await run()
        XCTAssertNil(after, "TTL 过期后应恢复真实签发")
        XCTAssertEqual(fetchCount.count, 2)
    }
}
