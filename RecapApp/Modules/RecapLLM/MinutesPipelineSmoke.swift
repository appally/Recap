import Foundation
import RecapModels

/// MinutesPipeline 冒烟：短转写 → 流式纪要 + null-safe 待办。
/// 需当前服务模式下 `LLMProviderFactory.makeCurrent()` 可用。
public enum MinutesPipelineSmoke {

    public static let sampleTranscript = """
    张明：那个我们这周把方案再过一下，预算这块我看了下，我觉得移动端这块投入得加大。
    李华：报价的话单台大概四百二吧，加上一年的服务费。
    张明：那移动端这块我们这季度就提到总预算的百分之三十。
    李华：行，那我周五之前把评审方案弄出来。
    张明：客户的报价我再确认一下。
    """

    /// 与生产管线一致：能 `makeCurrent()` 才算可用（BYOK 任意供应商 / 会员云）。
    public static var canRunMinutesPipeline: Bool {
        (try? LLMProviderFactory.makeCurrent()) != nil
    }

    /// 兼容旧调用；语义等同 `canRunMinutesPipeline`。
    public static var hasAPIKey: Bool { canRunMinutesPipeline }

    /// 异步带兜底的可用性检查（供 AI 对话 / 调研 / 技能等异步入口用）。
    /// - 同步闸门通过 -> 可用；
    /// - 免费档未过(token 瞬时未就绪) -> `ensureFresh(force:)` 强刷后重判（与纪要路径 `MeetingSession.startProcessing` 同构）；
    /// - BYOK 未配 key / recapCloud 非 Pro -> 永久态，不重试，直接返文案。
    /// 不可用时 `message` 为面向用户的文案（区分额度耗尽 / 网络瞬时 / 未配置）。
    public static func ensureCanRun() async -> (available: Bool, message: String?) {
        if canRunMinutesPipeline { return (true, nil) }
        switch AIServiceMode.current {
        case .freeTrial:
            do {
                try await RecapCredentialProvider.shared.ensureFresh(force: true)
            } catch {
                return (false, freeTrialFailureMessage(error))
            }
            return canRunMinutesPipeline ? (true, nil) : (false, "免费凭证尚未就绪，请稍后重试。")
        case .recapCloud:
            // Pro 失效但 mode 仍停在 recapCloud(降级漂移态):自愈回落免费档并重走,
            // 而非返回"暂未就绪/稍后再试"误导文案(该态为永久态,重试永不成功)。
            // 根因兜底在 MembershipStore.refreshEntitlements 降级同步;此处关闭启动竞态/旧版本残留。
            // mode 改 freeTrial 后必命中下方 freeTrial 分支,不会回入本分支(一次性)。
            // 免费额度耗尽时由 freeTrialFailureMessage 的 403 文案正确提示。
            guard RecapAccountStore.current.tier == .pro else {
                AIServiceMode.current = .freeTrial
                return await ensureCanRun()
            }
            do {
                try await RecapCredentialProvider.shared.ensureFresh(force: true)
            } catch {
                return (false, recapCloudFailureMessage(error))
            }
            return canRunMinutesPipeline ? (true, nil) : (false, "Pro 凭证尚未就绪，请稍后重试。")
        case .byok:
            return (false, "未配置可用的大模型密钥，请先在「设置 -> 大模型」里配置。")
        }
    }

    /// `ensureFresh` 失败文案:委托 RecapCredentialError.userMessage(解析 403 body 区分验证/额度,按 tier 兜底)。
    /// 免费档/Pro 档统一——漂移态(tier=pro 但 mode=freeTrial)时 fetchIssue 守卫已按 Pro 签发,
    /// 文案按 tier 给出「Pro 凭证签发被拒」而非误导性的「免费额度已用完」。
    private static func freeTrialFailureMessage(_ error: Error) -> String {
        (error as? RecapCredentialError)?.userMessage ?? "凭证准备失败，请检查网络后重试。"
    }

    private static func recapCloudFailureMessage(_ error: Error) -> String {
        (error as? RecapCredentialError)?.userMessage ?? "Pro 凭证准备失败，请检查网络后重试。"
    }

    /// 跑冒烟管线（调用方负责消费事件流）。
    public static func run() throws -> AsyncThrowingStream<MinutesEvent, Error> {
        let provider = try LLMProviderFactory.makeCurrent()
        return MinutesPipeline(provider: provider).run(transcript: sampleTranscript)
    }
}
