import XCTest
@testable import RecapLLM
import RecapModels

final class SearchTranscriptToolTests: XCTestCase {

    private func makeSeg(start: Double, end: Double, text: String, speaker: String = "s1") -> TranscriptSegment {
        TranscriptSegment(startSeconds: start, endSeconds: end, speakerId: speaker, text: text)
    }

    private var speakers: [Speaker] {
        [Speaker(id: "s1", name: "张明", colorIndex: 0)]
    }

    func testKeywordHitOnChineseSubstring() {
        let segs = [
            makeSeg(start: 0, end: 10, text: "本季客户回报率提升到百分之十二"),
            makeSeg(start: 20, end: 30, text: "闲聊天气不错"),
        ]
        let hits = SearchTranscriptTool.search(
            query: "回报率多少",
            segments: segs,
            speakers: speakers,
            limit: 6
        )
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.contains { $0.text.contains("回报率") })
    }

    func testRecentWindowSelectsTailSegments() {
        let segs = [
            makeSeg(start: 0, end: 10, text: "开头"),
            makeSeg(start: 100, end: 110, text: "中段"),
            makeSeg(start: 200, end: 210, text: "尾段内容"),
        ]
        let hits = SearchTranscriptTool.recent(
            segments: segs,
            speakers: speakers,
            withinMinutes: 2, // 120s
            nowSeconds: 210,
            limit: 12
        )
        XCTAssertTrue(hits.contains { $0.text.contains("尾段") })
        XCTAssertFalse(hits.contains { $0.text == "开头" })
    }

    func testAskQueryIntentRecentChips() {
        XCTAssertEqual(
            AskQueryIntentClassifier.classify("总结到此刻"),
            .recentWindow(minutes: 5)
        )
        XCTAssertEqual(
            AskQueryIntentClassifier.classify("还有什么未决"),
            .openItemsFocus
        )
        XCTAssertEqual(
            AskQueryIntentClassifier.classify("总结这场会议"),
            .fullMeetingRecap
        )
        XCTAssertEqual(
            AskQueryIntentClassifier.classify("报价多少"),
            .keywordSearch
        )
    }
}
