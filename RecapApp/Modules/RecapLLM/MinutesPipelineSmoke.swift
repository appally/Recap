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

    /// 跑冒烟管线（调用方负责消费事件流）。
    public static func run() throws -> AsyncThrowingStream<MinutesEvent, Error> {
        let provider = try LLMProviderFactory.makeCurrent()
        return MinutesPipeline(provider: provider).run(transcript: sampleTranscript)
    }
}
