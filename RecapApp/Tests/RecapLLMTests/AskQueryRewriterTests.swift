import XCTest
@testable import RecapLLM

final class AskQueryRewriterTests: XCTestCase {

    func testParseKeywordsCommaSeparated() {
        let kws = AskQueryRewriter.parseKeywords("报价, 预算, 负责人")
        XCTAssertEqual(kws, ["报价", "预算", "负责人"])
    }

    func testParseKeywordsDedupAndCap3() {
        let kws = AskQueryRewriter.parseKeywords("报价、报价、预算，价格，截止")
        XCTAssertEqual(kws.count, 3)
        XCTAssertEqual(kws.first, "报价")
    }

    func testShouldRewriteOnlyKeywordEmpty() {
        XCTAssertTrue(
            AskQueryRewriter.shouldRewrite(intent: .keywordSearch, localHitCount: 0)
        )
        XCTAssertFalse(
            AskQueryRewriter.shouldRewrite(intent: .keywordSearch, localHitCount: 2)
        )
    }

    func testShouldNotRewriteRecentWindowEvenIfEmpty() {
        XCTAssertFalse(
            AskQueryRewriter.shouldRewrite(
                intent: .recentWindow(minutes: 5),
                localHitCount: 0
            )
        )
        XCTAssertFalse(
            AskQueryRewriter.shouldRewrite(intent: .openItemsFocus, localHitCount: 0)
        )
    }
}
