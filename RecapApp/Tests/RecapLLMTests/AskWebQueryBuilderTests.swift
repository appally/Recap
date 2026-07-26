import XCTest
@testable import RecapLLM

final class AskWebQueryBuilderTests: XCTestCase {

    func testSanitizeStripsFollowUpPrefix() {
        let cleaned = AskWebQueryBuilder.sanitizeConversational(
            "基于你上一条回答，那个公司去年营收多少"
        )
        XCTAssertFalse(cleaned.contains("基于你上一条"))
        XCTAssertTrue(cleaned.contains("营收"))
    }

    func testBuildPrefersRewrittenLine() {
        let q = AskWebQueryBuilder.buildSearchQuery(
            raw: "基于你上一条回答，查一下 OpenAI",
            rewrittenLine: "OpenAI 最新估值"
        )
        XCTAssertEqual(q, "OpenAI 最新估值")
    }

    func testParseWebQueryLineRejectsEmpty() {
        XCTAssertNil(AskWebQueryBuilder.parseWebQueryLine("  \n  "))
        XCTAssertNil(AskWebQueryBuilder.parseWebQueryLine("a"))
    }

    func testParseWebQueryLineTakesFirstLine() {
        let line = AskWebQueryBuilder.parseWebQueryLine("\"竞品 估值\"\n解释：不要这行")
        XCTAssertEqual(line, "竞品 估值")
    }
}
