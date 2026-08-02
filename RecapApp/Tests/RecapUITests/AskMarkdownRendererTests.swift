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

    // MARK: - 表格（GFM）

    func testTableParsed() {
        let md = "| 名称 | 数值 |\n| --- | --- |\n| 甲 | 1 |\n| 乙 | 2 |"
        let blocks = MarkdownBlockParser.parse(md)
        XCTAssertEqual(blocks, [.table(
            header: ["名称", "数值"],
            aligns: [.left, .left],
            rows: [["甲", "1"], ["乙", "2"]]
        )])
    }

    func testTableAlignFromDelimiter() {
        let md = "| 左 | 中 | 右 |\n| :-- | :-: | --: |\n| a | b | c |"
        let blocks = MarkdownBlockParser.parse(md)
        XCTAssertEqual(blocks, [.table(
            header: ["左", "中", "右"],
            aligns: [.left, .center, .right],
            rows: [["a", "b", "c"]]
        )])
    }

    func testTableWithoutOuterPipes() {
        let md = "A | B\n-- | --\nx | y"
        let blocks = MarkdownBlockParser.parse(md)
        XCTAssertEqual(blocks, [.table(header: ["A", "B"], aligns: [.left, .left], rows: [["x", "y"]])])
    }

    /// 单元内的 `\|` 是字面竖线，不得被当列分隔符。
    func testEscapedPipeStaysInCell() {
        let md = "| 类型 | 说明 |\n| --- | --- |\n| a\\|b | c |"
        let blocks = MarkdownBlockParser.parse(md)
        XCTAssertEqual(blocks, [.table(
            header: ["类型", "说明"],
            aligns: [.left, .left],
            rows: [["a|b", "c"]]
        )])
    }

    /// 数据行列数不足 → 末列补空串，渲染层据此对齐成网格。
    func testTableShortRowPadded() {
        let md = "| a | b | c |\n|---|---|---|\n| 1 | 2 |"
        let blocks = MarkdownBlockParser.parse(md)
        XCTAssertEqual(blocks, [.table(
            header: ["a", "b", "c"],
            aligns: [.left, .left, .left],
            rows: [["1", "2", ""]]
        )])
    }

    /// 含 `|` 但缺合法分隔行 → 不算表格，回退普通段落（核心回归：旧实现会把竖线当文字乱排）。
    func testPipeLineWithoutDelimiterIsParagraph() {
        let blocks = MarkdownBlockParser.parse("单价 | 9 折")
        XCTAssertEqual(blocks, [.paragraph("单价 | 9 折")])
    }

    func testTableSitsBetweenParagraphs() {
        let md = "报价如下：\n\n| 名称 | 数值 |\n| --- | --- |\n| 甲 | 1 |\n\n以上。"
        let blocks = MarkdownBlockParser.parse(md)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .paragraph("报价如下："))
        XCTAssertEqual(blocks[1], .table(header: ["名称", "数值"], aligns: [.left, .left], rows: [["甲", "1"]]))
        XCTAssertEqual(blocks[2], .paragraph("以上。"))
    }

    // MARK: - mermaid

    /// ` ```mermaid ` 围栏解析为带 language 的 codeBlock（渲染层据此分流到 WebView）。
    func testMermaidFenceParsedAsCodeBlock() {
        let blocks = MarkdownBlockParser.parse("```mermaid\ngraph TD\nA-->B\n```")
        XCTAssertEqual(blocks, [.codeBlock(language: "mermaid", content: "graph TD\nA-->B")])
    }

    /// language 原样保留（大小写不敏感判定在渲染层 lowercased()=="mermaid"）。
    func testMermaidLanguagePreservedCaseInsensitive() {
        let blocks = MarkdownBlockParser.parse("```Mermaid\ngraph LR\nA-->B\n```")
        XCTAssertEqual(blocks, [.codeBlock(language: "Mermaid", content: "graph LR\nA-->B")])
    }

    /// source 注入 WebView 前 JSON 编码，必须能 round-trip（防引号/反斜杠/换行破坏 JS）。
    func testMermaidJsQuotedRoundTrips() {
        let raw = "a\"b\nc\\d\t中文节点"
        let quoted = MermaidDiagramView.Coordinator.jsQuoted(raw)
        XCTAssertTrue(quoted.hasPrefix("\"") && quoted.hasSuffix("\""), "应为合法 JS 字符串字面量：\(quoted)")
        let data = ("[" + quoted + "]").data(using: .utf8)!
        let decoded = (try? JSONSerialization.jsonObject(with: data) as? [String])?.first
        XCTAssertEqual(decoded, raw, "JSON 解码应还原原文：\(quoted)")
    }

    // MARK: - mermaid 源码归一化（防御层：剥误嵌套围栏 + 修剪空行，不改语法）

    /// 模型误嵌套的额外围栏（双围栏）须被剥掉，否则 mermaid.render 解析失败。
    func testMermaidNormalizerStripsDoubleFence() {
        let doubleFenced = "```mermaid\ngraph TD\nA-->B\n```"
        XCTAssertEqual(MermaidSourceNormalizer.normalize(doubleFenced), "graph TD\nA-->B")
    }

    /// 首尾空行 + 尾随围栏须一并修剪。
    func testMermaidNormalizerTrimsFenceAndBlanks() {
        let src = "\n\n```mermaid\ngraph TD\nA-->B\n```\n\n"
        XCTAssertEqual(MermaidSourceNormalizer.normalize(src), "graph TD\nA-->B")
    }

    /// 合法源码（无围栏）原样保留，仅修剪首尾空行；内部缩进不动。
    func testMermaidNormalizerPreservesValidSource() {
        let src = "graph TD\n  A[\"需求评审\"] --> B{\"方案可行?\"}"
        XCTAssertEqual(MermaidSourceNormalizer.normalize(src),
                       "graph TD\n  A[\"需求评审\"] --> B{\"方案可行?\"}")
    }

    /// 多重嵌套围栏须被全部剥掉。
    func testMermaidNormalizerStripsNestedFences() {
        let src = "```mermaid\n```\ngraph TD\nA-->B"
        XCTAssertEqual(MermaidSourceNormalizer.normalize(src), "graph TD\nA-->B")
    }

    /// 波浪号围栏同样识别。
    func testMermaidNormalizerHandlesTildeFence() {
        let src = "~~~mermaid\ngraph TD\nA-->B\n~~~"
        XCTAssertEqual(MermaidSourceNormalizer.normalize(src), "graph TD\nA-->B")
    }

    /// 空输入安全返回空。
    func testMermaidNormalizerEmptySafe() {
        XCTAssertEqual(MermaidSourceNormalizer.normalize(""), "")
        XCTAssertEqual(MermaidSourceNormalizer.normalize("\n  \n"), "")
    }
}
