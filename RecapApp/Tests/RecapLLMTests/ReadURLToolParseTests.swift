import XCTest
@testable import RecapLLM

final class ReadURLToolParseTests: XCTestCase {

    func testNormalizeCompressesBlankLinesAndTruncates() {
        let raw = "标题\n\n\n\n正文\n\n\n尾"
        let out = ReadURLTool.normalize(raw, maxChars: 8)
        XCTAssertFalse(out.contains("\n\n\n"))
        XCTAssertTrue(out.contains("…（已截断"))
    }

    func testIsAllowedPublicHTTPS() {
        XCTAssertTrue(ReadURLTool.isAllowed(URL(string: "https://example.com/a")!))
        XCTAssertTrue(ReadURLTool.isAllowed(URL(string: "http://example.org")!))
    }

    func testIsAllowedRejectsPrivateHosts() {
        let banned = [
            "http://localhost/x",
            "http://127.0.0.1/x",
            "http://10.0.0.5/x",
            "http://192.168.1.1/x",
            "http://169.254.1.1/x",
            "http://[::1]/x",
            "ftp://example.com",
            "file:///tmp/a",
        ]
        for s in banned {
            XCTAssertFalse(ReadURLTool.isAllowed(URL(string: s)!), s)
        }
    }

    func testJinaPrefixConstant() {
        XCTAssertEqual(ReadURLTool.jinaPrefix, "https://r.jina.ai/")
    }
}
