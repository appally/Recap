import Foundation
import SwiftUI

// MARK: - 块级模型

/// 助手回复 Markdown 的块级结构。仅承载纯文本（含行内 Markdown 源），
/// 不承载 AttributedString，以便解析层完全可单测。
public enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([String])
    case orderedList([String])
    case blockquote([String])
    case codeBlock(language: String?, content: String)
    case thematicBreak
}

/// 把助手回复 Markdown 拆成块。刻意只覆盖 LLM 常见输出：
/// 段落 / 标题 / 列表 / 引用 / 代码块 / 分隔线；不做完整 CommonMark（表格、深层嵌套）。
/// 关键作用：让本该换行的单换行不再被 `AttributedString(markdown:)` 折叠成空格。
public enum MarkdownBlockParser {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // 空行 = 段落边界
            if trimmed.isEmpty { i += 1; continue }

            // 围栏代码块
            if let fence = fenceMarker(trimmed) {
                var content: [String] = []
                var j = i + 1
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if let close = fenceMarker(t), close.char == fence.char, close.count >= fence.count {
                        break
                    }
                    content.append(lines[j])
                    j += 1
                }
                blocks.append(.codeBlock(language: fence.language, content: content.joined(separator: "\n")))
                i = (j < lines.count) ? j + 1 : j   // 跳过闭合围栏
                continue
            }

            // 标题（# ~ ######，# 后须空格或行尾）
            if let heading = headingInfo(trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            // 分隔线
            if isThematicBreak(trimmed) {
                blocks.append(.thematicBreak)
                i += 1
                continue
            }

            // 引用
            if blockquoteBody(trimmed) != nil {
                var items: [String] = []
                var j = i
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    if let body = blockquoteBody(t) { items.append(body); j += 1 } else { break }
                }
                blocks.append(.blockquote(items))
                i = j
                continue
            }

            // 无序列表
            if unorderedItemText(trimmed) != nil {
                let (items, consumed) = consumeList(lines: lines, start: i, marker: unorderedItemText)
                blocks.append(.unorderedList(items))
                i += consumed
                continue
            }

            // 有序列表
            if orderedItemText(trimmed) != nil {
                let (items, consumed) = consumeList(lines: lines, start: i, marker: orderedItemText)
                blocks.append(.orderedList(items))
                i += consumed
                continue
            }

            // 段落：连续非空、非块起始行，按单换行保留为硬换行
            var para: [String] = [trimmed]
            var j = i + 1
            while j < lines.count {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if isBlockStart(t) { break }
                para.append(t)
                j += 1
            }
            blocks.append(.paragraph(para.joined(separator: "\n")))
            // 防御：保证外层循环必定前进，任何分支意外不前进时也不至死循环卡死 UI。
            i = max(j, i + 1)
        }

        return blocks
    }

    // MARK: 行内收集

    /// 连续收集同类列表项；支持 2 空格 / Tab 缩进的续行并入上一项。
    private static func consumeList(
        lines: [String],
        start: Int,
        marker: (String) -> String?
    ) -> (items: [String], consumed: Int) {
        var items: [String] = []
        var j = start
        while j < lines.count {
            let raw = lines[j]
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            // 注意：这里不能再调 isBlockStart —— 它会把列表标记本身也算作块起始，
            // 导致首行就 break、consumed=0、外层 i 不前进而死循环。
            // 非同类行（标题 / 围栏 / 另一种列表 / 普通段落）天然不匹配 marker，
            // 也不是续行缩进，会落到下面的 else 分支正常 break。
            if let item = marker(t) {
                items.append(item)
                j += 1
            } else if !items.isEmpty, isContinuationIndent(raw) {
                items[items.count - 1] += "\n" + t
                j += 1
            } else {
                break
            }
        }
        return (items, j - start)
    }

    /// 任何块级结构的起始判定（用于段落的提前中止）。
    private static func isBlockStart(_ trimmed: String) -> Bool {
        headingInfo(trimmed) != nil
            || fenceMarker(trimmed) != nil
            || isThematicBreak(trimmed)
            || blockquoteBody(trimmed) != nil
            || unorderedItemText(trimmed) != nil
            || orderedItemText(trimmed) != nil
    }

    // MARK: 行识别

    private struct Fence { let char: Character; let count: Int; let language: String? }

    private static func fenceMarker(_ trimmed: String) -> Fence? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        let rest = trimmed.drop(while: { $0 == first }).trimmingCharacters(in: .whitespaces)
        return Fence(char: first, count: run.count, language: rest.isEmpty ? nil : rest)
    }

    private struct Heading { let level: Int; let text: String }

    private static func headingInfo(_ trimmed: String) -> Heading? {
        guard trimmed.hasPrefix("#") else { return nil }
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.drop(while: { $0 == "#" })
        // `#` 后须为空格或行尾，避免误判 #hashtag
        guard rest.isEmpty || rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return Heading(level: level, text: text)
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { !$0.isWhitespace }
        guard let marker = chars.first, marker == "-" || marker == "*" || marker == "_",
              chars.count >= 3 else { return false }
        return chars.allSatisfy { $0 == marker }
    }

    private static func blockquoteBody(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix(">") else { return nil }
        var rest = trimmed.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    /// `- ` / `* ` / `+ ` → 返回条目正文。
    private static func unorderedItemText(_ trimmed: String) -> String? {
        guard let first = trimmed.first, first == "-" || first == "+" || first == "*" else { return nil }
        let after = trimmed.dropFirst()
        guard after.first == " " || after.first == "\t" else { return nil }
        let text = after.drop(while: { $0 == " " || $0 == "\t" })
        guard !text.isEmpty else { return nil }
        return String(text)
    }

    /// `1. ` / `2) ` → 返回条目正文（仅剥离标记，编号在视图层自增）。
    private static func orderedItemText(_ trimmed: String) -> String? {
        var idx = trimmed.startIndex
        var digits = 0
        while idx < trimmed.endIndex, trimmed[idx].isNumber {
            idx = trimmed.index(after: idx); digits += 1
        }
        guard digits >= 1, idx < trimmed.endIndex else { return nil }
        let delim = trimmed[idx]
        guard delim == "." || delim == ")" else { return nil }
        let after = trimmed.index(after: idx)
        guard after < trimmed.endIndex, trimmed[after] == " " || trimmed[after] == "\t" else { return nil }
        let text = trimmed[after...].drop(while: { $0 == " " || $0 == "\t" })
        guard !text.isEmpty else { return nil }
        return String(text)
    }

    private static func isContinuationIndent(_ raw: String) -> Bool {
        var spaces = 0
        for ch in raw.prefix(4) {
            if ch == " " { spaces += 1 }
            else if ch == "\t" { return true }
            else { break }
        }
        return spaces >= 2
    }
}

// MARK: - 行内渲染

/// Ask 助手气泡受限 Markdown：纯函数解析（可单测）。
public enum AskMarkdownRenderer {
    private static var parsingOptions: AttributedString.MarkdownParsingOptions {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return options
    }

    /// 将助手回复（单段，可能含多行）转为可显示的 AttributedString。
    /// 逐行解析行内 Markdown 后用显式 `\n` 拼接，**避免单个换行被软换行折叠成空格**。
    /// 解析失败时回退纯文字（永不抛到 UI）。
    public static func attributed(_ source: String) -> AttributedString {
        let lines = source.components(separatedBy: "\n")
        guard lines.count > 1 else {
            return applyRecapTypography(parseInline(source))
        }
        var combined = AttributedString()
        for (idx, line) in lines.enumerated() {
            if idx > 0 { combined += AttributedString("\n") }
            combined += parseInline(line)
        }
        return applyRecapTypography(combined)
    }

    /// 单行行内渲染（标题、列表条目等已知单行场景）。
    public static func attributedInline(_ source: String) -> AttributedString {
        applyRecapTypography(parseInline(source))
    }

    /// 可见纯文字（去掉 Markdown 围栏符号后的阅读串），供单测断言。
    public static func plainVisible(_ source: String) -> String {
        String(attributed(source).characters)
    }

    private static func parseInline(_ source: String) -> AttributedString {
        if let parsed = try? AttributedString(markdown: source, options: parsingOptions) {
            return parsed
        }
        return AttributedString(source)
    }

    private static func applyRecapTypography(_ input: AttributedString) -> AttributedString {
        var output = input
        for run in output.runs {
            let range = run.range
            if output[range].link != nil {
                // 中性体系：链接靠下划线区分于正文，不靠彩色（与 recapInk 正文同色）。
                output[range].underlineStyle = .single
                continue
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                output[range].font = .body.monospaced()
                output[range].backgroundColor = Color.recapInk.opacity(0.06)
                output[range].foregroundColor = Color.recapInk
                continue
            }
            if output[range].foregroundColor == nil {
                output[range].foregroundColor = Color.recapInk
            }
        }
        return output
    }
}

// MARK: - 视图

/// 助手气泡 Markdown 视图：块级排版（段落 / 标题 / 列表 / 引用 / 代码块），
/// 流式 ≥50ms 防抖，结束立即终解析。
public struct AskMarkdownText: View {
    public let source: String
    public var isStreaming: Bool = false

    @State private var blocks: [MarkdownBlock] = []
    @State private var debounceTask: Task<Void, Never>?

    public init(source: String, isStreaming: Bool = false) {
        self.source = source
        self.isStreaming = isStreaming
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Color.recapInk)
        .tint(Color.recapInk)
        .textSelection(.enabled)
        .onChange(of: source, initial: true) { _, newValue in
            scheduleRender(newValue, streaming: isStreaming)
        }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                debounceTask?.cancel()
                blocks = MarkdownBlockParser.parse(source)
            }
        }
        .onDisappear { debounceTask?.cancel() }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(AskMarkdownRenderer.attributed(text))
                .font(.recapRaw)
                .lineSpacing(4)

        case .heading(let level, let text):
            Text(AskMarkdownRenderer.attributedInline(text))
                .font(headingFont(level))
                .padding(.top, Spacing.xs)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    bulletRow(marker: "•", text: item, monospacedMarker: false)
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    bulletRow(marker: "\(idx + 1).", text: item, monospacedMarker: true)
                }
            }

        case .blockquote(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, line in
                    Text(AskMarkdownRenderer.attributed(line))
                        .font(.system(size: 14, weight: .regular, design: .default))
                        .foregroundStyle(Color.recapTea)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, Spacing.md)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.recapTea.opacity(0.35))
                    .frame(width: 2)
            }

        case .codeBlock(_, let content):
            Text(content)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.sm + 2)
                .background(
                    Color.recapInk.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

        case .thematicBreak:
            Divider()
                .background(Color.recapTea.opacity(0.3))
        }
    }

    @ViewBuilder
    private func bulletRow(marker: String, text: String, monospacedMarker: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm - 2) {
            Text(marker)
                .font(monospacedMarker
                      ? .system(size: 15, weight: .regular, design: .monospaced)
                      : .recapRaw)
                .foregroundStyle(Color.recapTea)
            Text(AskMarkdownRenderer.attributed(text))
                .font(.recapRaw)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 19, weight: .semibold, design: .default)
        case 2: return .system(size: 17, weight: .semibold, design: .default)
        case 3: return .system(size: 16, weight: .semibold, design: .default)
        default: return .system(size: 15, weight: .semibold, design: .default)
        }
    }

    private func scheduleRender(_ text: String, streaming: Bool) {
        if !streaming {
            debounceTask?.cancel()
            blocks = MarkdownBlockParser.parse(text)
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            blocks = MarkdownBlockParser.parse(text)
        }
    }
}
