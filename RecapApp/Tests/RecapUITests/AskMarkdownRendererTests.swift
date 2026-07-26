import XCTest
@testable import RecapUI

final class AskMarkdownRendererTests: XCTestCase {

    func testBoldStripsMarkers() {
        let visible = AskMarkdownRenderer.plainVisible("结论是 **通过**。")
        XCTAssertTrue(visible.contains("通过"))
        XCTAssertFalse(visible.contains("**"))
    }

    func testInlineCodeStripsBackticks() {
        let visible = AskMarkdownRenderer.plainVisible("用 `mm:ss` 标注")
        XCTAssertTrue(visible.contains("mm:ss"))
        XCTAssertFalse(visible.contains("`"))
    }

    func testLinkHasURL() {
        let attr = AskMarkdownRenderer.attributed("[议程](https://example.com)")
        var found: URL?
        for run in attr.runs {
            if let link = run.link {
                found = link
                break
            }
        }
        XCTAssertEqual(found?.absoluteString, "https://example.com")
        let visible = String(attr.characters)
        XCTAssertTrue(visible.contains("议程"))
    }

    func testPlainFallbackEqualsSource() {
        let source = "今天拍板了报价口径。"
        XCTAssertEqual(AskMarkdownRenderer.plainVisible(source), source)
    }

    func testListSmoke() {
        let visible = AskMarkdownRenderer.plainVisible("- a\n- b")
        XCTAssertTrue(visible.contains("a"))
        XCTAssertTrue(visible.contains("b"))
    }

    func testMalformedDoesNotThrow() {
        let source = "**未闭合加粗与 [坏链]("
        let visible = AskMarkdownRenderer.plainVisible(source)
        XCTAssertFalse(visible.isEmpty)
    }
}
