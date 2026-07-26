import XCTest
@testable import RecapLLM

final class SSELineParserTests: XCTestCase {

    func testDataWithSpace() {
        XCTAssertEqual(
            SSELineParser.classify("data: {\"a\":1}"),
            .data("{\"a\":1}")
        )
    }

    func testDataWithoutSpace() {
        XCTAssertEqual(
            SSELineParser.classify("data:{\"a\":1}"),
            .data("{\"a\":1}")
        )
    }

    func testDone() {
        XCTAssertEqual(SSELineParser.classify("data: [DONE]"), .done)
        XCTAssertEqual(SSELineParser.classify("data:[DONE]"), .done)
    }

    func testEmptyAndCommentAndEvent() {
        XCTAssertEqual(SSELineParser.classify(""), .ignorable)
        XCTAssertEqual(SSELineParser.classify(": ping"), .ignorable)
        XCTAssertEqual(SSELineParser.classify("event: message"), .ignorable)
        XCTAssertEqual(SSELineParser.classify("id: 1"), .ignorable)
    }

    func testCRLFTrailingCRStripped() {
        XCTAssertEqual(
            SSELineParser.classify("data: {\"x\":1}\r"),
            .data("{\"x\":1}")
        )
    }
}
