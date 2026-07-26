import XCTest
@testable import RecapLLM

final class StableContentHashTests: XCTestCase {

    func testHashStableAcrossCalls() {
        let a = StableContentHash.short("https://example.com/a")
        let b = StableContentHash.short("https://example.com/a")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 12)
    }

    func testDifferentInputsDiffer() {
        let a = StableContentHash.short("https://example.com/a")
        let b = StableContentHash.short("https://example.com/b")
        XCTAssertNotEqual(a, b)
    }

    func testCitationIdsDoNotUseHashValue() {
        let hit = WebHit(title: "T", url: "https://example.com/x", content: "c")
        let cite = AskCitation.from(hit)
        XCTAssertTrue(cite.id.hasPrefix("w-"))
        XCTAssertFalse(cite.id.contains("Optional"))
        // 同一 URL 两次构造 id 相同
        XCTAssertEqual(cite.id, AskCitation.from(hit).id)

        let tHit = TranscriptHit(startSeconds: 99.49, speakerName: "张", text: "报价 420")
        let tCite = AskCitation.from(tHit)
        XCTAssertEqual(tCite.id, AskCitation.from(tHit).id)
        XCTAssertTrue(tCite.id.hasPrefix("t-"))
    }
}
