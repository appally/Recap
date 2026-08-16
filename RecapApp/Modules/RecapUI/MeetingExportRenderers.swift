import SwiftUI
import UIKit

/// 导出文件送系统分享面板（plan 048）：临时 URL → UIActivityViewController。
/// ShareLink 需要静态 item，导出物按需生成，故走 representable sheet。
struct ExportActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 导出渲染器（plan 048 Wave B）：纪要 Markdown → PDF / 长图 PNG。
///
/// 共用一条排版管线：`MarkdownBlockParser.parse` → 块级 NSAttributedString（行内经
/// `AskMarkdownRenderer.attributedInline`，复用既有排版与 emoji 保护）→ CoreText 布局分块。
/// mermaid / 思维导图块降级为源码文本（WKWebView 离屏快照不可靠，v1 决策，
/// 见 `MindmapOutlineView` 头注释先例）。
enum MeetingExportRenderers {

    /// AI 声明（与屏显 `AILightDisclaimer` 同文案；导出物是转交付物，必须带）。
    static let disclaimer = "内容由 AI 生成，仅供参考"

    // MARK: - 块级 NSAttributedString 构造

    private struct Block {
        let attributed: NSAttributedString
        let spacingAfter: CGFloat
    }

    /// 逐块构造 NSAttributedString（每块自带上下留白，绘制时按基线推进）。
    private static func makeBlocks(markdown: String) -> [Block] {
        MarkdownBlockParser.parse(markdown).map { block in
            switch block {
            case .heading(let level, let text):
                let size: CGFloat = level <= 1 ? 24 : (level == 2 ? 19 : 16)
                return Block(
                    attributed: nsString(AskMarkdownRenderer.attributedInline(text),
                                         font: .systemFont(ofSize: size, weight: .semibold),
                                         color: .black),
                    spacingAfter: 10
                )
            case .paragraph(let text):
                return Block(
                    attributed: nsString(AskMarkdownRenderer.attributedInline(text),
                                         font: .systemFont(ofSize: 15),
                                         color: .darkGray),
                    spacingAfter: 12
                )
            case .unorderedList(let items):
                let joined = items.map { "•  " + $0 }.joined(separator: "\n")
                return Block(
                    attributed: nsString(AskMarkdownRenderer.attributed(joined),
                                         font: .systemFont(ofSize: 15),
                                         color: .darkGray),
                    spacingAfter: 12
                )
            case .orderedList(let items):
                let joined = items.enumerated()
                    .map { "\($0.offset + 1).  \($0.element)" }
                    .joined(separator: "\n")
                return Block(
                    attributed: nsString(AskMarkdownRenderer.attributed(joined),
                                         font: .systemFont(ofSize: 15),
                                         color: .darkGray),
                    spacingAfter: 12
                )
            case .blockquote(let items):
                return Block(
                    attributed: nsString(AskMarkdownRenderer.attributed(items.joined(separator: "\n")),
                                         font: .italicSystemFont(ofSize: 15),
                                         color: .gray),
                    spacingAfter: 12
                )
            case .codeBlock(let language, let content):
                // mermaid/思维导图源码在导出物中以文本呈现（降级决策）
                let label = (language ?? "").isEmpty ? "" : "〔\(language!)〕\n"
                return Block(
                    attributed: nsString(AttributedString(label + content),
                                         font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                         color: .darkGray),
                    spacingAfter: 12
                )
            case .thematicBreak:
                return Block(
                    attributed: NSAttributedString(string: "──────────",
                                                    attributes: [.font: UIFont.systemFont(ofSize: 12),
                                                                 .foregroundColor: UIColor.gray]),
                    spacingAfter: 12
                )
            case .table(let header, _, let rows):
                var lines: [String] = []
                lines.append(header.joined(separator: "  |  "))
                lines.append(String(repeating: "─", count: 24))
                for row in rows {
                    lines.append(row.joined(separator: "  |  "))
                }
                return Block(
                    attributed: nsString(AttributedString(lines.joined(separator: "\n")),
                                         font: .systemFont(ofSize: 13),
                                         color: .darkGray),
                    spacingAfter: 12
                )
            }
        }
    }

    /// AttributedString → NSAttributedString，统一字体/文字色。
    ///
    /// ⚠️ SwiftUI 的 `Font`/`Color` 属性经 `NSAttributedString(_:)` 转换后停留在私有键
    /// （`SwiftUI.Font`），CoreText/字符串绘制一概不认——修复前所有正文块按默认 12pt
    /// Helvetica 级联布局，字号/字重/斜体全丢。字体必须在 UIKit 侧 `addAttribute` 重设；
    /// 行内意图（**粗体**/*斜体*/`代码`）在此映射回 UIFont 变体。
    /// internal 供回归测试断言行距与字体桥接。
    static func nsString(_ source: AttributedString,
                         font: UIFont,
                         color: UIColor) -> NSAttributedString {
        var mutable = source
        mutable.font = Font(font)
        mutable.foregroundColor = Color(color)
        let result = NSMutableAttributedString(mutable)
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: font, range: full)
        result.addAttribute(.foregroundColor, value: color, range: full)
        for run in mutable.runs {
            guard let intent = run.inlinePresentationIntent, !intent.isEmpty else { continue }
            let nsRange = NSRange(run.range, in: mutable)
            let resolved: UIFont
            if intent.contains(.code) {
                resolved = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            } else {
                var traits = font.fontDescriptor.symbolicTraits
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if traits != font.fontDescriptor.symbolicTraits,
                   let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                    resolved = UIFont(descriptor: descriptor, size: 0)
                } else {
                    resolved = font
                }
            }
            result.addAttribute(.font, value: resolved, range: nsRange)
        }
        return result
    }

    private static func titleBlock(_ title: String) -> Block {
        Block(
            attributed: NSAttributedString(
                string: title,
                attributes: [.font: UIFont.systemFont(ofSize: 26, weight: .bold),
                             .foregroundColor: UIColor.black]
            ),
            spacingAfter: 6
        )
    }

    private static func metaBlock(_ text: String) -> Block {
        Block(
            attributed: NSAttributedString(
                string: text,
                attributes: [.font: UIFont.systemFont(ofSize: 11),
                             .foregroundColor: UIColor.gray]
            ),
            spacingAfter: 20
        )
    }

    // MARK: - PDF

    /// A4 纵向 PDF；页脚页码 + AI 声明。
    static func renderPDF(markdown: String, title: String, dateText: String) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 @72dpi
        let margin: CGFloat = 48
        let contentWidth = pageRect.width - margin * 2
        let blocks = [titleBlock(title), metaBlock(dateText)] + makeBlocks(markdown: markdown)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { ctx in
            var y: CGFloat = .infinity
            var pageNumber = 0
            for block in blocks {
                let frames = lineFragments(of: block.attributed, width: contentWidth)
                for (fragment, fragmentHeight) in frames {
                    if y + fragmentHeight > pageRect.height - margin - 24 {
                        // 换页：先给上一页补页脚
                        if pageNumber > 0 { drawFooter(in: ctx.cgContext, page: pageNumber, rect: pageRect, margin: margin) }
                        ctx.beginPage()
                        pageNumber += 1
                        y = margin
                    }
                    fragment.draw(at: CGPoint(x: margin, y: y))
                    y += fragmentHeight + 2
                }
                y += block.spacingAfter
            }
            if pageNumber > 0 { drawFooter(in: ctx.cgContext, page: pageNumber, rect: pageRect, margin: margin) }
        }
    }

    private static func drawFooter(in cg: CGContext, page: Int, rect: CGRect, margin: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray,
        ]
        let left = NSAttributedString(string: disclaimer, attributes: attrs)
        let right = NSAttributedString(string: "\(page)", attributes: attrs)
        left.draw(at: CGPoint(x: margin, y: rect.height - margin + 18))
        right.draw(at: CGPoint(x: rect.width - margin - 8, y: rect.height - margin + 18))
    }

    // MARK: - 长图

    /// 单张 PNG（宽 750pt @2x）；总高上限 16000pt（位图上下文安全上限内），
    /// 截断时尾部追加提示。**只用于纪要**——逐字稿长图内存失控（勘察风险 2）。
    static func renderLongImage(markdown: String, title: String, dateText: String) -> UIImage {
        let width: CGFloat = 375
        let scale: CGFloat = 2
        let margin: CGFloat = 24
        let contentWidth = width - margin * 2
        let heightCap: CGFloat = 8000 // pt（×2 scale = 16000px）

        let blocks = [titleBlock(title), metaBlock(dateText)] + makeBlocks(markdown: markdown)
        // 先量高
        var totalHeight: CGFloat = margin * 2
        var measured: [(attributed: NSAttributedString, y: CGFloat)] = []
        for block in blocks {
            for (fragment, h) in lineFragments(of: block.attributed, width: contentWidth) {
                measured.append((fragment, totalHeight))
                totalHeight += h + 2
            }
            totalHeight += block.spacingAfter
        }
        var truncated = false
        if totalHeight > heightCap {
            truncated = true
            totalHeight = heightCap
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: totalHeight), format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: totalHeight))
            for (fragment, y) in measured where y < heightCap - 30 {
                fragment.draw(at: CGPoint(x: margin, y: y))
            }
            if truncated {
                let note = NSAttributedString(
                    string: "……（内容过长已截断，完整纪要请导出 PDF）",
                    attributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.gray]
                )
                note.draw(at: CGPoint(x: margin, y: heightCap - 26))
            }
            // 底部声明
            let foot = NSAttributedString(
                string: disclaimer,
                attributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray]
            )
            foot.draw(at: CGPoint(x: margin, y: totalHeight - 18))
        }
    }

    // MARK: - 布局

    /// 把整块 NSAttributedString 按 CTFramesetter 切成行 fragment（保留原属性），
    /// 返回 [(可绘制片段, 推进高度)]。行高优先取相邻行 origin 差（含空行/行距，最稳），
    /// 末行回退光学高度。块间换行由调用方的 spacingAfter 提供。
    /// internal 供回归测试断言行距不塌缩。
    ///
    /// ⚠️ 帧高不能用 `.greatestFiniteMagnitude`：首行 origin.y ≈ 帧高（1.8e308），
    /// double 在该量级的精度间隔远大于行高，相邻 origin 相减恒为 0 → 每行 advance
    /// 全部落进 `max(advance, 4)` 的 4pt 兜底 → 导出物行行压叠（2026-08-16 实测）。
    /// 单块排版不过数千 pt，1e5 绰绰有余且精度无损。
    static func lineFragments(of attributed: NSAttributedString,
                              width: CGFloat) -> [(NSAttributedString, CGFloat)] {
        guard attributed.length > 0 else { return [] }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let cfLines = CTFrameGetLines(frame) as NSArray
        let lines = cfLines as? [CTLine] ?? []
        guard !lines.isEmpty else { return [(attributed, lineHeight(attributed))] }

        var origins = [CGPoint](repeating: .zero, count: lines.count)
        origins.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), base)
        }

        var result: [(NSAttributedString, CGFloat)] = []
        for (i, line) in lines.enumerated() {
            let range = CTLineGetStringRange(line)
            guard range.length > 0 else { continue }
            let fragment = attributed.attributedSubstring(
                from: NSRange(location: range.location, length: range.length)
            )
            // CT 坐标 y 向上：相邻 origin 差即行推进高度；末行用光学高度回退
            let advance: CGFloat
            if i + 1 < origins.count {
                advance = origins[i].y - origins[i + 1].y
            } else {
                advance = max(CTLineGetBoundsWithOptions(line, .useOpticalBounds).height,
                              lineHeight(attributed))
            }
            result.append((fragment, max(advance, 4)))
        }
        return result
    }

    private static func lineHeight(_ attributed: NSAttributedString) -> CGFloat {
        guard attributed.length > 0,
              let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont else {
            return 16
        }
        return font.lineHeight
    }
}
