import XCTest
@testable import RecapUI
@testable import RecapASR
import RecapModels

/// 会后自动云端重转的决策纯函数 + 舞台文案。
/// 原则锚点：纪要质量不打折（缺口必补）+ 延迟也是体验（干净云端不重复精转）
/// + 隐私边界（Pro 显式选端侧音频不上云）。
@MainActor
final class AutoCloudRetranscribeTests: XCTestCase {

    // MARK: - Pro 质量承诺

    func testProFallsBackToOnDeviceAlwaysRetranscribes() {
        // Pro 回落端侧（auto 偏好云端准备失败）→ 无条件精转（方言判定不再是闸门）
        XCTAssertEqual(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: true, liveDegraded: false,
            proHosted: true, freeTrialEligible: false, dialectVerdict: .keep), .pro)
        XCTAssertEqual(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: true, liveDegraded: false,
            proHosted: true, freeTrialEligible: false, dialectVerdict: .retranscribe), .pro)
    }

    func testProDegradedCloudLiveGetsRepair() {
        // Pro 云端 LIVE 中途降级（断连/滞后/中断）→ 补精转修复
        XCTAssertEqual(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .funASR, fellBackFromCloud: false, liveDegraded: true,
            proHosted: true, freeTrialEligible: false, dialectVerdict: .keep), .pro)
    }

    func testProCleanCloudLiveSkipsForLatency() {
        // 干净云端直出 → 不重转（精转增益≈0，却把纪要延迟一整个精转时长）
        XCTAssertNil(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .funASR, fellBackFromCloud: false, liveDegraded: false,
            proHosted: true, freeTrialEligible: false, dialectVerdict: .keep))
    }

    func testProExplicitOnDeviceRespectsPrivacyChoice() {
        // Pro 显式选端侧（非回落）→ 不自动上云；方言判定命中走 .dialect（既有语义）
        XCTAssertNil(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: false, liveDegraded: false,
            proHosted: true, freeTrialEligible: false, dialectVerdict: .keep))
        XCTAssertEqual(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: false, liveDegraded: false,
            proHosted: true, freeTrialEligible: false, dialectVerdict: .retranscribe), .dialect)
    }

    // MARK: - 免费档云端体验（首 3 场）

    func testFreeTrialEligibleGetsCloudTasteRegardlessOfEngine() {
        XCTAssertEqual(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: false, liveDegraded: false,
            proHosted: false, freeTrialEligible: true, dialectVerdict: .keep), .freeTrial)
    }

    func testFreeTrialExhaustedKeepsDialectOnly() {
        // 体验次数用完 → 维持方言判定（不双烧免费 ASR 桶）
        XCTAssertNil(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: true, liveDegraded: false,
            proHosted: false, freeTrialEligible: false, dialectVerdict: .keep))
        XCTAssertEqual(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: false, liveDegraded: false,
            proHosted: false, freeTrialEligible: false, dialectVerdict: .retranscribe), .dialect)
    }

    // MARK: - 语言精修（英文会议 → 英文模型重转）

    func testEnglishMeetingWithChineseOnlyEngineRetranscribes() {
        // 分类为英文 + LIVE 引擎无英文能力 → .language（免费/BYOK 语义，方言之外的新闸门）
        XCTAssertEqual(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: false, liveDegraded: false,
            proHosted: false, freeTrialEligible: false, dialectVerdict: .keep,
            language: .en, liveEnglishCapable: false), .language)
        XCTAssertEqual(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .funASR, fellBackFromCloud: false, liveDegraded: false,
            proHosted: true, freeTrialEligible: false, dialectVerdict: .keep,
            language: .en, liveEnglishCapable: false), .language)
    }

    func testEnglishMeetingWithEnglishCapableLiveSkips() {
        // 端侧双模块（zh+en）就绪 / 英文云端 LIVE → 已出英文，不重复烧云端
        XCTAssertNil(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: false, liveDegraded: false,
            proHosted: false, freeTrialEligible: false, dialectVerdict: .keep,
            language: .en, liveEnglishCapable: true))
    }

    func testChineseMeetingNeverTriggersLanguageRetranscribe() {
        // zh/mixed 不触发语言精修（zh 引擎本就覆盖混说）
        XCTAssertNil(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: false, liveDegraded: false,
            proHosted: false, freeTrialEligible: false, dialectVerdict: .keep,
            language: .zh, liveEnglishCapable: false))
        XCTAssertNil(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: false, liveDegraded: false,
            proHosted: false, freeTrialEligible: false, dialectVerdict: .keep,
            language: .mixed, liveEnglishCapable: false))
    }

    func testEnglishDialectVerdictDoesNotShadowLanguage() {
        // 英文场即便方言判定命中，语言精修仍优先（英文模型是根因修复）
        XCTAssertEqual(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: false, liveDegraded: false,
            proHosted: false, freeTrialEligible: false, dialectVerdict: .retranscribe,
            language: .en, liveEnglishCapable: false), .language)
    }

    // MARK: - 会中声学实锤（liveDetectedEnglish）

    func testLiveDetectedEnglishForcesLanguageEvenWithEnglishCapableEngine() {
        // 会中已切英文引擎（enCapable=true）也要精转：头部 zh 旧稿仍是乱码，
        // 且分类器可能被头部乱码误导判成 zh——声学信号优先于文本分类
        XCTAssertEqual(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .funASREn, fellBackFromCloud: false, liveDegraded: false,
            proHosted: true, freeTrialEligible: false, dialectVerdict: .keep,
            language: .zh, liveEnglishCapable: true, liveDetectedEnglish: true), .language)
        // 检测命中但切换被门槛拦下（显式端侧/免费档端侧）：头部乱稿仍在，修复照样触发
        XCTAssertEqual(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: false, liveDegraded: false,
            proHosted: false, freeTrialEligible: false, dialectVerdict: .keep,
            language: .zh, liveEnglishCapable: false, liveDetectedEnglish: true), .language)
    }

    // MARK: - 混说精修（mixed + 托管云端中文模型）

    func testMixedMeetingOnHostedParaformerGetsLanguageRetranscribe() {
        // paraformer 官方明示「中英混说除外」：混说场用 fun-asr-realtime 重转补缺口
        XCTAssertEqual(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .funASR, fellBackFromCloud: false, liveDegraded: false,
            proHosted: true, freeTrialEligible: false, dialectVerdict: .keep,
            language: .mixed, liveEnglishCapable: false), .language)
    }

    func testMixedMeetingByokFunAsrSkipsRetranscribe() {
        // BYOK 本就是 fun-asr-realtime（多语言混说长项）——重转同模型无增益，不烧用户 key
        XCTAssertNil(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .funASR, fellBackFromCloud: false, liveDegraded: false,
            proHosted: false, freeTrialEligible: false, dialectVerdict: .keep,
            language: .mixed, liveEnglishCapable: false))
    }

    func testMixedMeetingOnDeviceKeepsOldSemantics() {
        // 端侧双模块混说本就覆盖：维持旧语义（方言判定除外）
        XCTAssertNil(MeetingSession.autoCloudRetranscribeReason(
            engineKind: .speechAnalyzer, fellBackFromCloud: false, liveDegraded: false,
            proHosted: true, freeTrialEligible: false, dialectVerdict: .keep,
            language: .mixed, liveEnglishCapable: true))
    }

    // MARK: - 舞台文案

    func testStageTitles() {
        XCTAssertEqual(PipelineStage.retranscribing(.dialect).title, "检测到方言口音，云端精转中…")
        XCTAssertEqual(PipelineStage.retranscribing(.onDevice).title, "本机高保真精转中…")
        XCTAssertEqual(PipelineStage.retranscribing(.pro).title, "云端高保真精转中…")
        XCTAssertEqual(PipelineStage.retranscribing(.freeTrial).title, "云端高保真精转中…（免费体验）")
        XCTAssertEqual(PipelineStage.retranscribing(.language).title, "检测到英文会议，云端英文精转中…")
        XCTAssertTrue(PipelineStage.retranscribing(.pro).isProcessingStage)
        XCTAssertTrue(PipelineStage.retranscribing(.freeTrial).isProcessingStage)
        XCTAssertTrue(PipelineStage.retranscribing(.language).isProcessingStage)
    }

    // MARK: - freeTrial 截断拼接（P1 回归：截 10min × 整表覆盖 → 尾部静默丢失）

    func testSplicedFreeTrialSegmentsKeepsTailBeyondCap() {
        // 15min 会议：云端稿只覆盖 0..<600s；LIVE 600s 之后的尾段必须保留
        let live = [
            TranscriptSegment(startSeconds: 0, endSeconds: 300, text: "前半"),
            TranscriptSegment(startSeconds: 300, endSeconds: 600, text: "中段"),
            TranscriptSegment(startSeconds: 600, endSeconds: 900, text: "LIVE 尾段"),
        ]
        let cloud = [TranscriptSegment(startSeconds: 0, endSeconds: 300, text: "云端精转稿")]
        let spliced = MeetingSession.splicedFreeTrialSegments(new: cloud, old: live, capSeconds: 600)
        XCTAssertEqual(spliced.map(\.text), ["云端精转稿", "LIVE 尾段"], "云端稿替换前 10min，尾段保留")
        XCTAssertEqual(spliced.last?.startSeconds, 600, "时间轴连续不回退")
    }

    func testSplicedFreeTrialSegmentsBoundaryAtCap() {
        // 恰好 600s 起的段属于尾段（slice 用 < cap 比较，splice 用 >= cap——两侧同界无缝）
        let live = [
            TranscriptSegment(startSeconds: 599, endSeconds: 600, text: "界内"),
            TranscriptSegment(startSeconds: 600, endSeconds: 700, text: "界外"),
        ]
        let spliced = MeetingSession.splicedFreeTrialSegments(new: [], old: live, capSeconds: 600)
        XCTAssertEqual(spliced.map(\.text), ["界外"])
    }

    func testSplicedFreeTrialSegmentsShortMeetingNoTail() {
        // ≤10min 会议无尾段：等价整表替换
        let live = [TranscriptSegment(startSeconds: 0, endSeconds: 420, text: "全场")]
        let cloud = [TranscriptSegment(startSeconds: 0, endSeconds: 420, text: "云端稿")]
        let spliced = MeetingSession.splicedFreeTrialSegments(new: cloud, old: live, capSeconds: 600)
        XCTAssertEqual(spliced.map(\.text), ["云端稿"])
    }

    // MARK: - 会中英文检测的会后复核（liveEnglishCorroborated，P0-3）

    func testCorroborateNotDetectedAlwaysFalse() {
        XCTAssertFalse(MeetingSession.liveEnglishCorroborated(
            liveDetectedEnglish: false, switchElapsed: nil, segments: []))
        XCTAssertFalse(MeetingSession.liveEnglishCorroborated(
            liveDetectedEnglish: false, switchElapsed: 600,
            segments: [TranscriptSegment(startSeconds: 0, endSeconds: 900, text: "all english here")]))
    }

    func testCorroboratePostSwitchChineseTextRejects() {
        // 误判场景：切换后新引擎（LIVE 不锁语种）产出中文 → 复核不过 → 不放大成 .language，
        // 方言重转等常规路径照常参与
        let zhLong = String(repeating: "切换后引擎持续产出中文定稿内容", count: 10)
        let segs = [
            TranscriptSegment(startSeconds: 0, endSeconds: 600, text: "e a o e a o"),
            TranscriptSegment(startSeconds: 600, endSeconds: 900, text: zhLong),
        ]
        XCTAssertFalse(MeetingSession.liveEnglishCorroborated(
            liveDetectedEnglish: true, switchElapsed: 600, segments: segs))
    }

    func testCorroboratePostSwitchEnglishTextConfirms() {
        // 真英文会议：切换后文本判 en → 佐证成立（头部 zh 乱稿不拖累）
        let enLong = String(repeating: "the engine keeps producing english transcript text ", count: 3)
        let segs = [
            TranscriptSegment(startSeconds: 0, endSeconds: 600, text: "泽 恩德 奥夫 泽 布朗兹 爱己"),
            TranscriptSegment(startSeconds: 600, endSeconds: 900, text: enLong),
        ]
        XCTAssertTrue(MeetingSession.liveEnglishCorroborated(
            liveDetectedEnglish: true, switchElapsed: 600, segments: segs))
    }

    func testCorroboratePostSwitchInsufficientSampleTrustsWindows() {
        // 切后样本不足 120 字符（会议将散）：切换本身已是强证据，信两连窗口检测
        let segs = [
            TranscriptSegment(startSeconds: 0, endSeconds: 890, text: "中文为主的一场会议内容"),
            TranscriptSegment(startSeconds: 890, endSeconds: 900, text: "ok"),
        ]
        XCTAssertTrue(MeetingSession.liveEnglishCorroborated(
            liveDetectedEnglish: true, switchElapsed: 880, segments: segs))
    }

    func testCorroborateBlockedSwitchUsesTail() {
        // 切换被门槛拦下（switchElapsed=nil，engine 未变）：用尾巴文本复核——
        // 尾巴正是命中检测的英文窗口，头部 CJK 乱稿不再误导
        let enTail = [
            TranscriptSegment(startSeconds: 0, endSeconds: 600, text: "泽 恩德 奥夫 泽 布朗兹 爱己"),
            TranscriptSegment(startSeconds: 600, endSeconds: 900,
                              text: String(repeating: "the tail of the meeting is english ", count: 5)),
        ]
        XCTAssertTrue(MeetingSession.liveEnglishCorroborated(
            liveDetectedEnglish: true, switchElapsed: nil, segments: enTail))
        let zhTail = [
            TranscriptSegment(startSeconds: 0, endSeconds: 600,
                              text: String(repeating: "the quick brown fox jumps over ", count: 4)),
            TranscriptSegment(startSeconds: 600, endSeconds: 900,
                              text: String(repeating: "会议尾巴其实是中文内容为主也要覆盖", count: 8)),
        ]
        XCTAssertFalse(MeetingSession.liveEnglishCorroborated(
            liveDetectedEnglish: true, switchElapsed: nil, segments: zhTail))
    }

    func testCorroborateBlockedSwitchNoSampleRejects() {
        // 无从佐证 → 不放大（宁可漏放行交方言/常规路径兜底）
        XCTAssertFalse(MeetingSession.liveEnglishCorroborated(
            liveDetectedEnglish: true, switchElapsed: nil, segments: []))
    }

    // MARK: - 拒收量化日志 & 免费档熔断

    func testRejectMetricsComputesCharsSpanAndRatio() {
        // 拒绝日志的量化串：字数/时长/比值——事后区分「网络残稿」「临界误杀」「原稿虚胖」的唯一证据
        let old = [
            TranscriptSegment(startSeconds: 0, endSeconds: 580, text: String(repeating: "旧", count: 300)),
            TranscriptSegment(startSeconds: 580, endSeconds: 600, text: String(repeating: "稿", count: 100)),
        ]
        let new = [
            TranscriptSegment(startSeconds: 0, endSeconds: 300, text: String(repeating: "新", count: 150)),
        ]
        let metrics = MeetingSession.retranscribeRejectMetrics(new: new, old: old)
        XCTAssertTrue(metrics.contains("old=400c/600s"), metrics)
        XCTAssertTrue(metrics.contains("new=150c/300s"), metrics)
        XCTAssertTrue(metrics.contains("ratio=38%"), metrics)
        // 空新稿（重转近乎无输出的极端形态）不崩，比值 0
        XCTAssertTrue(MeetingSession.retranscribeRejectMetrics(new: [], old: old).contains("ratio=0%"))
    }

    func testFreeTrialFusePausesAfterTwoMissesAndResetsOnSuccess() {
        let suite = "test.cloudTrialFuse.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // 单次未兑现：不熔断（隔离偶发失败，不烧体验场）
        XCTAssertFalse(MeetingSession.isFreeTrialAutoPaused(defaults: defaults))
        MeetingSession.recordFreeTrialRetranscribeMiss(defaults: defaults)
        XCTAssertFalse(MeetingSession.isFreeTrialAutoPaused(defaults: defaults))
        // 连续第二次 → 熔断 7 天；期满解禁
        MeetingSession.recordFreeTrialRetranscribeMiss(defaults: defaults)
        XCTAssertTrue(MeetingSession.isFreeTrialAutoPaused(defaults: defaults))
        XCTAssertFalse(MeetingSession.isFreeTrialAutoPaused(
            now: Date().addingTimeInterval(8 * 86_400), defaults: defaults))
        // 成功兑现 → 复位计数与暂停期
        MeetingSession.resetFreeTrialRetranscribeMisses(defaults: defaults)
        XCTAssertFalse(MeetingSession.isFreeTrialAutoPaused(defaults: defaults))
    }
}
