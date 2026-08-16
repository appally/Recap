import XCTest
import UIKit
@testable import RecapUI

/// 导出排版管线回归（2026-08-16 行行压叠修复）：
/// 1) 行推进高度不再塌缩——帧高 `greatestFiniteMagnitude` 时相邻 origin 相减恒 0，
///    每行 advance 落进 4pt 兜底，导出 PDF/长图行距≈字重叠；
/// 2) SwiftUI `Font`/`Color` 停留在私有键不桥接——修复前所有正文块按默认 12pt
///    Helvetica 级联布局，字号/字重/斜体全丢。
final class MeetingExportRenderersTests: XCTestCase {

    private let contentWidth: CGFloat = 595 - 48 * 2 // A4 @72dpi 内容宽

    private func listBlock() -> NSAttributedString {
        let source = AskMarkdownRenderer.attributed(
            "•  **投资提案**：总预算 30%，采用「单设备 420 元」报价方案\n" +
            "•  决议：报价方案通过，李华本周五前出评审案\n" +
            "•  整理报价对比表，张明跟进确认客户报价与采购结论"
        )
        return MeetingExportRenderers.nsString(source,
                                               font: .systemFont(ofSize: 15),
                                               color: .darkGray)
    }

    // MARK: - 行距

    func testLineAdvancesNotCollapsed() {
        let fragments = MeetingExportRenderers.lineFragments(of: listBlock(), width: contentWidth)
        XCTAssertGreaterThanOrEqual(fragments.count, 3, "多行列表应切出多行 fragment")
        // 15pt systemFont 行高 ≈ 17.9；压叠回归时 advance 全为 4
        for (_, advance) in fragments {
            XCTAssertGreaterThan(advance, 14,
                                 "行推进高度塌缩（advance=\(advance)），行距压叠回归")
        }
    }

    func testSingleLineAdvanceCoversFontLineHeight() {
        let heading = MeetingExportRenderers.nsString(
            AskMarkdownRenderer.attributedInline("议题纪要"),
            font: .systemFont(ofSize: 16, weight: .semibold),
            color: .black
        )
        let fragments = MeetingExportRenderers.lineFragments(of: heading, width: contentWidth)
        XCTAssertEqual(fragments.count, 1)
        XCTAssertGreaterThan(fragments[0].1, 16) // 末行回退光学高度/字体行高
    }

    // MARK: - 字体桥接

    func testFontBridgedToUIFont() {
        let attr = listBlock()
        var sawFont = false
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
            guard let font = value as? UIFont else {
                XCTFail("字体未桥接为 UIFont（SwiftUI.Font 私有键回归）")
                return
            }
            XCTAssertEqual(font.pointSize, 15)
            sawFont = true
        }
        XCTAssertTrue(sawFont)
        XCTAssertEqual(attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
                       .darkGray)
    }

    func testBoldRunResolvesToBoldFont() {
        let attr = listBlock()
        let plain = attr.string as NSString
        let boldRange = plain.range(of: "投资提案")
        XCTAssertEqual(boldRange.length, 4, "**…** 标记应被剥除且文本保留")
        guard let font = attr.attribute(.font, at: boldRange.location, effectiveRange: nil) as? UIFont else {
            XCTFail("粗体 run 无 UIFont")
            return
        }
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold),
                      "行内粗体意图应映射为 bold 字体变体")
    }

    func testCodeRunResolvesToMonospace() {
        let attr = MeetingExportRenderers.nsString(
            AskMarkdownRenderer.attributedInline("报价 `420 元` 通过"),
            font: .systemFont(ofSize: 15),
            color: .darkGray
        )
        let plain = attr.string as NSString
        let codeRange = plain.range(of: "420 元")
        guard codeRange.length > 0,
              let font = attr.attribute(.font, at: codeRange.location, effectiveRange: nil) as? UIFont else {
            XCTFail("行内代码 run 缺失")
            return
        }
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace),
                      "行内代码意图应映射为等宽字体")
    }

    // MARK: - 导出物冒烟

    func testRenderPDFProducesNonEmptySinglePageData() {
        let markdown = """
        ## 议题纪要

        本次会议敲定移动端预算提案，总预算 30%，采用「单设备 420 元」报价方案。

        - **投资提案**：总预算 30% 上浮，覆盖三个季度
        - 决议：报价方案通过，李华本周五前出评审案

        > 未决问题：是否纳入 iPad 端采购？
        """
        let data = MeetingExportRenderers.renderPDF(markdown: markdown,
                                                    title: "周会·产品评审",
                                                    dateText: "2026年8月16日")
        XCTAssertGreaterThan(data.count, 10_000)
        // 修复前行距塌缩时全部内容挤进 ~200pt，与正常行距的页数不同；
        // 此内容正常排版恰好一页，若压叠回归也不会小于一页——用页数上限兜住失控情况
        let pageCount = pageCount(of: data)
        XCTAssertEqual(pageCount, 1, "短内容应恰好一页")
    }

    func testRenderLongImageProducesImage() {
        let image = MeetingExportRenderers.renderLongImage(
            markdown: "- 甲项：预算 30%\n- 乙项：报价 420 元",
            title: "周会·产品评审",
            dateText: "2026年8月16日"
        )
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 100, "行距塌缩时长图总高会异常偏小")
    }

    // MARK: - 辅助

    private func pageCount(of pdfData: Data) -> Int {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }
}
