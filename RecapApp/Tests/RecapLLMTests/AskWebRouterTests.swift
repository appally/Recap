import XCTest
@testable import RecapLLM
import RecapModels

final class AskWebRouterTests: XCTestCase {

    func testDisabledNeverNeedsWeb() {
        XCTAssertFalse(AskWebRouter.needsWeb(
            query: "查一下竞品定价",
            webEnabled: false,
            localHitCount: 0
        ))
    }

    func testKeywordWithEnabled() {
        XCTAssertTrue(AskWebRouter.needsWeb(
            query: "查一下 Swift 并发",
            webEnabled: true,
            localHitCount: 3
        ))
    }

    func testLocalEmptyTriggersWebWhenEnabled() {
        XCTAssertTrue(AskWebRouter.needsWeb(
            query: "报价多少",
            webEnabled: true,
            localHitCount: 0
        ))
    }

    func testMeetingPriceWithLocalHitsSkipsWeb() {
        XCTAssertFalse(AskWebRouter.needsWeb(
            query: "报价多少",
            webEnabled: true,
            localHitCount: 2
        ))
    }

    func testExternalFactNotBlockedByLocalHits() {
        XCTAssertTrue(AskWebRouter.needsWeb(
            query: "竞品估值多少",
            webEnabled: true,
            localHitCount: 2
        ))
        XCTAssertTrue(AskWebRouter.needsWeb(
            query: "最新汇率",
            webEnabled: true,
            localHitCount: 3
        ))
    }

    func testMeetingInternalChipSkipsWebEvenIfLocalEmpty() {
        XCTAssertFalse(AskWebRouter.needsWeb(
            query: "总结到此刻",
            webEnabled: true,
            localHitCount: 0
        ))
        XCTAssertFalse(AskWebRouter.needsWeb(
            query: "还有什么未决",
            webEnabled: true,
            localHitCount: 0
        ))
    }

    func testCitationKindsStable() {
        let t = AskCitation.from(TranscriptHit(startSeconds: 90, speakerName: "张明", text: "报价 420"))
        let b = AskCitation.from(BriefHit(
            id: "s-0",
            sourceId: UUID(),
            sourceTitle: "议案",
            role: .proposal,
            text: "回报率 12.5%"
        ))
        let w = AskCitation.from(WebHit(title: "示例", url: "https://example.com", content: "摘要"))
        XCTAssertEqual(t.kind, .transcript)
        XCTAssertEqual(b.kind, .brief)
        XCTAssertEqual(w.kind, .web)
        XCTAssertNotEqual(t.id, b.id)
        XCTAssertNotEqual(b.id, w.id)
    }
}
