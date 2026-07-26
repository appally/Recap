import XCTest
@testable import RecapLLM

final class QueryTokenizerTests: XCTestCase {

    func testChineseChipProducesMultipleTokens() {
        let tokens = QueryTokenizer.tokenize("总结到此刻")
        XCTAssertGreaterThan(tokens.count, 1)
        XCTAssertFalse(tokens.count == 1 && tokens.contains("总结到此刻"))
    }

    func testEnglishTokensPreserved() {
        let tokens = QueryTokenizer.tokenize("Swift concurrency pricing")
        XCTAssertTrue(tokens.contains("swift") || tokens.contains("Swift"))
        XCTAssertTrue(tokens.contains { $0.localizedCaseInsensitiveContains("pricing") })
    }

    func testMixedQuery() {
        let tokens = QueryTokenizer.tokenize("回报率 12.5%")
        XCTAssertTrue(tokens.contains { $0.contains("回报") || $0 == "回报率" })
        XCTAssertTrue(tokens.contains { $0.contains("12") })
    }
}
