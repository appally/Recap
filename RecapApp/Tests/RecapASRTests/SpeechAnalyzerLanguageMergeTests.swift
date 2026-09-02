import XCTest
@testable import RecapASR
import RecapModels

/// SpeechAnalyzer 双转写器（zh-CN + en-US）的择优合并逻辑（纯函数）。
/// 原则：中文会场字幕稳定（含 CJK 优先）；纯外文看置信度；打平 zh 兜底——避免语言来回闪。
@available(iOS 26.0, *)
final class SpeechAnalyzerLanguageMergeTests: XCTestCase {

    // MARK: - shouldReplace（同刻定稿择优）

    func testHigherConfidenceWins() {
        XCTAssertTrue(SpeechAnalyzerEngine.shouldReplace(
            existing: (text: "今天开会", confidence: 0.4),
            new: (text: "今天开会", confidence: 0.9),
            newIsZh: true))
        XCTAssertFalse(SpeechAnalyzerEngine.shouldReplace(
            existing: (text: "今天开会", confidence: 0.9),
            new: (text: "今天开会", confidence: 0.4),
            newIsZh: true))
    }

    func testConfidencePresentBeatsMissing() {
        XCTAssertTrue(SpeechAnalyzerEngine.shouldReplace(
            existing: (text: "garbage", confidence: nil),
            new: (text: "the end of the bronze age", confidence: 0.8),
            newIsZh: false))
        XCTAssertFalse(SpeechAnalyzerEngine.shouldReplace(
            existing: (text: "the end of the bronze age", confidence: 0.8),
            new: (text: "garbage", confidence: nil),
            newIsZh: false))
    }

    func testCJKBeatsNonCJKWhenConfidenceTied() {
        // 一侧中文一侧纯外文且置信度打平 → 含 CJK 者胜（中文是主语言，且 zh 模型对英文只出乱码）
        XCTAssertTrue(SpeechAnalyzerEngine.shouldReplace(
            existing: (text: "th bar of the moter age", confidence: nil),
            new: (text: "今天会议讨论了项目进度", confidence: nil),
            newIsZh: true))
    }

    func testEnglishMeetingZhGarbageReplacedByEn() {
        // 纯英文场：zh 模型出音素乱码（无 CJK）、en 模型出好稿，置信度打平 →
        // 纯外文内容 en 优先——这正是本特性要修的核心场景。
        XCTAssertTrue(SpeechAnalyzerEngine.shouldReplace(
            existing: (text: "th bart of the moter age", confidence: 0.5),
            new: (text: "the end of the Bronze Age", confidence: 0.5),
            newIsZh: false))
    }

    func testZhWinsOnFullCjkTie() {
        // 中文内容全打平（同置信度、同为中文）→ zh 主语言兜底
        XCTAssertTrue(SpeechAnalyzerEngine.shouldReplace(
            existing: (text: "今天会议讨论项目", confidence: nil),
            new: (text: "今天会议讨论项目", confidence: nil),
            newIsZh: true))
        XCTAssertFalse(SpeechAnalyzerEngine.shouldReplace(
            existing: (text: "今天会议讨论项目", confidence: nil),
            new: (text: "今天会议讨论项目", confidence: nil),
            newIsZh: false))
    }

    func testNonCJKFullTiePrefersEn() {
        // 纯外文全打平 → en 模型优先（zh 模型对英文只是音素乱码）
        XCTAssertFalse(SpeechAnalyzerEngine.shouldReplace(
            existing: (text: "hello world", confidence: nil),
            new: (text: "hello world", confidence: nil),
            newIsZh: true))
        XCTAssertTrue(SpeechAnalyzerEngine.shouldReplace(
            existing: (text: "hello world", confidence: nil),
            new: (text: "hello world", confidence: nil),
            newIsZh: false))
    }

    // MARK: - preferredPartial（实时字幕择优）

    func testPartialPrefersCJK() {
        XCTAssertEqual(SpeechAnalyzerEngine.preferredPartial(
            zh: (text: "我们在讨论古希腊", confidence: nil),
            en: (text: "th greek stow of ar thisious", confidence: nil)), "我们在讨论古希腊")
    }

    func testPartialPrefersEnglishWhenZhGarbage() {
        // 纯英文场：zh 模型只出音素乱码（无 CJK）→ en 候选胜
        XCTAssertEqual(SpeechAnalyzerEngine.preferredPartial(
            zh: (text: "th bart of the moter age", confidence: nil),
            en: (text: "the end of the Bronze Age", confidence: nil)), "the end of the Bronze Age")
    }

    func testPartialConfidenceBreaksForeignTie() {
        XCTAssertEqual(SpeechAnalyzerEngine.preferredPartial(
            zh: (text: "th bart of the moter", confidence: nil),
            en: (text: "the end of the Bronze", confidence: 0.9)), "the end of the Bronze")
        XCTAssertEqual(SpeechAnalyzerEngine.preferredPartial(
            zh: (text: "th bart of the moter", confidence: 0.95),
            en: (text: "the end of the Bronze", confidence: 0.9)), "th bart of the moter")
    }

    func testPartialSingleSideFallsBack() {
        XCTAssertEqual(SpeechAnalyzerEngine.preferredPartial(zh: nil, en: (text: "en only", confidence: nil)), "en only")
        XCTAssertEqual(SpeechAnalyzerEngine.preferredPartial(zh: (text: "中文 only", confidence: nil), en: nil), "中文 only")
        XCTAssertNil(SpeechAnalyzerEngine.preferredPartial(zh: nil, en: nil))
    }

    // MARK: - 粘性语言（近期定稿胜方优先，修英文会议 CJK 幻觉草稿压正确 en 草稿）

    func testStickyEnKeepsZhCjkHallucinationOutOfDraft() {
        // 英文会议（近期定稿胜方=en）：zh 模块吐出 CJK 音译幻觉草稿——含 CJK 优先倾向
        // 在此是反作用，粘性 en 直接压掉
        XCTAssertEqual(SpeechAnalyzerEngine.preferredPartial(
            zh: (text: "泽 恩德 奥夫 泽 布朗兹 爱己", confidence: nil),
            en: (text: "the end of the Bronze Age", confidence: nil),
            sticky: .en), "the end of the Bronze Age")
    }

    func testStickyZhKeepsChineseStable() {
        // 中文会议（粘性 zh）：en 模块偶发拉丁草稿不再打断中文字幕
        XCTAssertEqual(SpeechAnalyzerEngine.preferredPartial(
            zh: (text: "我们在讨论古希腊", confidence: nil),
            en: (text: "the greek story of athena", confidence: nil),
            sticky: .zh), "我们在讨论古希腊")
    }

    func testStickySideMissingFallsBackToHeuristic() {
        // 粘性侧暂无草稿（清空/停更）→ 回落既有启发式，不返回 nil 卡死字幕
        XCTAssertEqual(SpeechAnalyzerEngine.preferredPartial(
            zh: (text: "我们在讨论古希腊", confidence: nil),
            en: nil,
            sticky: .en), "我们在讨论古希腊")
        XCTAssertNil(SpeechAnalyzerEngine.preferredPartial(zh: nil, en: nil, sticky: .en))
    }

    // MARK: - zh 偏置（中文会场：CJK 先于置信度/粘性——方言场景防 en 幻觉反杀）

    func testZhBiasCJKBeatsHigherConfidenceEnglish() {
        // 方言压塌 zh 置信（0.3）、en 幻觉置信中高（0.8）：zh 偏置下正确中文不被反杀
        XCTAssertFalse(SpeechAnalyzerEngine.shouldReplace(
            existing: (text: "今天会议讨论项目进度", confidence: 0.3),
            new: (text: "the meeting discussed progress", confidence: 0.8),
            newIsZh: false, bias: .zh))
        // 反向：正确中文挑战英文旧稿 → 替换
        XCTAssertTrue(SpeechAnalyzerEngine.shouldReplace(
            existing: (text: "the meeting discussed progress", confidence: 0.8),
            new: (text: "今天会议讨论项目进度", confidence: 0.3),
            newIsZh: true, bias: .zh))
    }

    func testZhBiasForeignBothSidesKeepsConfidenceOrder() {
        // 两侧都无 CJK（zh 模型对英文只出音素乱码）→ 维持原序，不因偏置劣化
        XCTAssertTrue(SpeechAnalyzerEngine.shouldReplace(
            existing: (text: "th bart of the moter age", confidence: 0.5),
            new: (text: "the end of the Bronze Age", confidence: 0.5),
            newIsZh: false, bias: .zh))
    }

    func testZhBiasStickyEnglishDoesNotLockCJKDraft() {
        // 一次误胜的 en 定稿（sticky=.en）不得把字幕锁死英文：zh 草稿含 CJK 优先
        XCTAssertEqual(SpeechAnalyzerEngine.preferredPartial(
            zh: (text: "我们在讨论项目进度", confidence: nil),
            en: (text: "we are discussing progress", confidence: nil),
            sticky: .en, bias: .zh), "我们在讨论项目进度")
    }

    func testZhBiasStickyStillBreaksForeignTie() {
        // 两侧都无 CJK（纯英文插句）→ 粘性照旧防字幕语言闪动
        XCTAssertEqual(SpeechAnalyzerEngine.preferredPartial(
            zh: (text: "th greek stow", confidence: nil),
            en: (text: "the greek story", confidence: nil),
            sticky: .en, bias: .zh), "the greek story")
    }
}