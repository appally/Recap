import XCTest
@testable import RecapUI

final class AskMarkdownRendererTests: XCTestCase {

    // MARK: - 行内渲染

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

    func testMalformedDoesNotThrow() {
        let source = "**未闭合加粗与 [坏链]("
        let visible = AskMarkdownRenderer.plainVisible(source)
        XCTAssertFalse(visible.isEmpty)
    }

    // MARK: - 换行回归（核心修复）

    /// 单换行必须保留为硬换行，而不是被 CommonMark 软换行折叠成空格。
    /// 旧实现（整段塞进单个 AttributedString）会让本断言拿到 "第一行 第二行"。
    func testSingleNewlinePreservedAsHardBreak() {
        let visible = AskMarkdownRenderer.plainVisible("第一行\n第二行")
        XCTAssertEqual(visible, "第一行\n第二行")
        XCTAssertFalse(visible.contains("第一行 第二行"))
    }

    /// 列表条目必须各自独占一行（旧 `testListSmoke` 只断言 a/b 存在，漏掉了换行）。
    func testListItemsRenderOnSeparateLines() {
        let visible = AskMarkdownRenderer.plainVisible("- a\n- b")
        XCTAssertTrue(visible.contains("a"))
        XCTAssertTrue(visible.contains("b"))
        XCTAssertTrue(visible.contains("\n"), "列表条目应分行，却挤成了一行：\(visible)")
    }

    // MARK: - 块级解析

    func testParagraphSplitByBlankLine() {
        let blocks = MarkdownBlockParser.parse("段一\n\n段二")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks, [.paragraph("段一"), .paragraph("段二")])
    }

    func testUnorderedListParsed() {
        let blocks = MarkdownBlockParser.parse("- 要点一\n- 要点二\n- 要点三")
        XCTAssertEqual(blocks, [.unorderedList(["要点一", "要点二", "要点三"])])
    }

    func testOrderedListParsed() {
        let blocks = MarkdownBlockParser.parse("1. 第一步\n2. 第二步")
        XCTAssertEqual(blocks, [.orderedList(["第一步", "第二步"])])
    }

    func testMixedStarBullet() {
        let blocks = MarkdownBlockParser.parse("* 甲\n* 乙")
        XCTAssertEqual(blocks, [.unorderedList(["甲", "乙"])])
    }

    func testHeadingParsed() {
        let blocks = MarkdownBlockParser.parse("## 要点标题")
        XCTAssertEqual(blocks, [.heading(level: 2, text: "要点标题")])
    }

    func testHashtagNotTreatedAsHeading() {
        let blocks = MarkdownBlockParser.parse("这是 #hashtag 不是标题")
        XCTAssertEqual(blocks, [.paragraph("这是 #hashtag 不是标题")])
    }

    func testCodeBlockParsed() {
        let md = "```swift\nlet x = 1\nlet y = 2\n```"
        let blocks = MarkdownBlockParser.parse(md)
        XCTAssertEqual(blocks, [.codeBlock(language: "swift", content: "let x = 1\nlet y = 2")])
    }

    func testCodeBlockWithoutLanguage() {
        let md = "```\nplain code\n```"
        let blocks = MarkdownBlockParser.parse(md)
        XCTAssertEqual(blocks, [.codeBlock(language: nil, content: "plain code")])
    }

    func testBlockquoteParsed() {
        let blocks = MarkdownBlockParser.parse("> 引用第一行\n> 引用第二行")
        XCTAssertEqual(blocks, [.blockquote(["引用第一行", "引用第二行"])])
    }

    func testThematicBreakParsed() {
        let blocks = MarkdownBlockParser.parse("上文\n\n---\n\n下文")
        XCTAssertEqual(blocks, [
            .paragraph("上文"),
            .thematicBreak,
            .paragraph("下文")
        ])
    }

    /// 端到端：一段典型的助手回复应拆成多个块，而非一整段。
    func testTypicalAssistantReplySplitsIntoBlocks() {
        let md = """
        本次讨论有三个要点：

        1. **报价**：保持 9 折
        2. **跟进**：下周联系王总

        建议提前准备方案文档。
        """
        let blocks = MarkdownBlockParser.parse(md)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .paragraph("本次讨论有三个要点："))
        XCTAssertEqual(blocks[1], .orderedList(["**报价**：保持 9 折", "**跟进**：下周联系王总"]))
        XCTAssertEqual(blocks[2], .paragraph("建议提前准备方案文档。"))
    }
}
