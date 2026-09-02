import XCTest
import RecapModels

/// 转写语言分类器（纯函数）：CJK/Latin 字母占比 → zh / en / mixed。
/// 这是多语言零摩擦体验的第一环——录音结束自动判定，驱动引擎与 LLM 语言适配。
final class TranscriptLanguageClassifierTests: XCTestCase {

    func testPureChineseIsZh() {
        XCTAssertEqual(TranscriptLanguageClassifier.classify(text: "今天开会讨论了项目进度，下周交付。"),
                       .zh)
    }

    func testPureEnglishIsEn() {
        XCTAssertEqual(TranscriptLanguageClassifier.classify(
            text: "The Bronze Age collapse just like the Greek story of the Trojan war"),
                       .en)
    }

    func testChineseWithScatteredEnglishIsZh() {
        // 中英混说（中文为主）→ zh：paraformer-v2 / 双模块天然覆盖，无需英文模型
        XCTAssertEqual(TranscriptLanguageClassifier.classify(text: "这个 OKR 我们要对齐一下，下周 review。"),
                       .zh)
    }

    func testBalancedMixIsMixed() {
        XCTAssertEqual(TranscriptLanguageClassifier.classify(text: "Today we talked about 项目进度 and 下周交付."),
                       .mixed)
    }

    func testEmptyFallsBackToZh() {
        XCTAssertEqual(TranscriptLanguageClassifier.classify(text: ""), .zh)
        XCTAssertEqual(TranscriptLanguageClassifier.classify([]), .zh)
    }

    func testPunctuationAndDigitsIgnored() {
        let en = "0:00 speaker 1: the end of the bronze age, in any case, 4000 years ago!"
        XCTAssertEqual(TranscriptLanguageClassifier.classify(text: en), .en)
    }

    func testEngineLanguageMapping() {
        XCTAssertEqual(MeetingLanguage.en.engineLanguage, .en)
        XCTAssertEqual(MeetingLanguage.zh.engineLanguage, .zh)
        XCTAssertEqual(MeetingLanguage.mixed.engineLanguage, .zh, "mixed 按 zh 引擎走（双模块/混说模型覆盖）")
    }

    func testContainsCJK() {
        XCTAssertTrue(TranscriptLanguageClassifier.containsCJK("你好 world"))
        XCTAssertFalse(TranscriptLanguageClassifier.containsCJK("hello world"))
        XCTAssertFalse(TranscriptLanguageClassifier.containsCJK(""))
    }

    func testSegmentsAggregated() {
        let segments = [
            TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "Hello there, how are you?"),
            TranscriptSegment(startSeconds: 2, endSeconds: 4, text: "I am fine, thanks for asking."),
        ]
        XCTAssertEqual(TranscriptLanguageClassifier.classify(segments), .en)
    }

    // MARK: - 抗乱稿（P1-3：单字符拉丁串不计语言证据——方言语气词罗马化残迹）

    func testSingleLetterLatinStormIsNotEnglish() {
        // 方言乱稿整窗单字符碎片（嗯/哦/啊的罗马化）→ 旧口径 100% Latin 误判 en
        XCTAssertEqual(TranscriptLanguageClassifier.classify(text: "e a o e a o e a o e a o e a o e a o e"), .zh)
    }

    func testStrayLettersDoNotDrownChinese() {
        // 中文夹零星单字母残迹：不影响 zh 判定
        XCTAssertEqual(TranscriptLanguageClassifier.classify(text: "我们讨论一下 e 这个方案 a 怎么落地 o 还要看预算"), .zh)
    }

    func testRealEnglishUnaffectedByTokenRule() {
        let en = String(repeating: "the meeting covered project timelines ", count: 5)
        XCTAssertEqual(TranscriptLanguageClassifier.classify(text: en), .en)
    }
}