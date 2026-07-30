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
    case table(header: [String], aligns: [MarkdownTableAlign], rows: [[String]])
}

/// GFM 表格列对齐方式（由分隔行 `:--` / `--:` / `:-:` 推导）。
public enum MarkdownTableAlign: Equatable {
    case left, center, right
}

/// 把助手回复 Markdown 拆成块。刻意只覆盖 LLM 常见输出：
/// 段落 / 标题 / 列表 / 引用 / 代码块 / 分隔线 / 表格；不做完整 CommonMark（深层嵌套）。
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

            // GFM 表格：当前行含 `|`，且紧随一行为合法分隔行（`|---|---|`）
            if let table = tableBlock(lines: lines, start: i) {
                blocks.append(table.block)
                i += table.consumed
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

    // MARK: 表格（GFM）

    /// 从 `start` 起尝试解析一张 GFM 表格。要求 start 行为表头（含 `|`），
    /// start+1 行为合法分隔行；返回 nil 表示此处不是表格（交回段落处理）。
    /// 列数以「表头与分隔行的较大者」为准，数据行不足补空、多余截断。
    private static func tableBlock(lines: [String], start: Int) -> (block: MarkdownBlock, consumed: Int)? {
        guard start + 1 < lines.count else { return nil }
        guard lines[start].contains("|") else { return nil }
        let delim = splitCells(lines[start + 1])
        guard !delim.isEmpty, delim.allSatisfy(isDelimiterCell) else { return nil }

        let header = splitCells(lines[start])
        let colCount = max(header.count, delim.count)
        let aligns = paddedAligns(delim, count: colCount)

        var rows: [[String]] = []
        var j = start + 2
        while j < lines.count {
            let t = lines[j].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }          // 空行结束表格
            if !t.contains("|") { break }   // 非 `|` 行不属于表格
            rows.append(padCells(splitCells(lines[j]), count: colCount))
            j += 1
        }
        return (.table(header: padCells(header, count: colCount), aligns: aligns, rows: rows), j - start)
    }

    /// 把一行切成单元格：去掉两侧外框 `|`，按 `|` 分割（`\|` 视为单元内字面竖线），逐段 trim。
    private static func splitCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        let placeholder = "\u{0}"
        let marked = s.replacingOccurrences(of: "\\|", with: placeholder)
        return marked.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: placeholder, with: "|")
        }
    }

    /// 合法分隔单元格：`:?-+:?`，至少一个 `-`。
    private static func isDelimiterCell(_ cell: String) -> Bool {
        let s = cell.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        var idx = s.startIndex
        if s[idx] == ":" { idx = s.index(after: idx) }
        guard idx < s.endIndex, s[idx] == "-" else { return false }
        while idx < s.endIndex, s[idx] == "-" { idx = s.index(after: idx) }
        if idx < s.endIndex, s[idx] == ":" { idx = s.index(after: idx) }
        return idx == s.endIndex
    }

    /// 由分隔单元格推导对齐：`:-:` 中 / `--:` 右 / 其余左（含默认 `---`）。
    private static func alignOf(_ cell: String) -> MarkdownTableAlign {
        let s = cell.trimmingCharacters(in: .whitespaces)
        switch (s.hasPrefix(":"), s.hasSuffix(":")) {
        case (true, true): return .center
        case (false, true): return .right
        default: return .left
        }
    }

    private static func paddedAligns(_ delim: [String], count: Int) -> [MarkdownTableAlign] {
        var a = delim.map { alignOf($0) }
        while a.count < count { a.append(.left) }
        return a
    }

    private static func padCells(_ cells: [String], count: Int) -> [String] {
        var c = cells
        while c.count < count { c.append("") }
        return Array(c.prefix(count))
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

/// 流式吐字落字光标：电光青/极光平滑 Sin 呼吸波度游标。
public struct StreamingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = reduceMotion ? 0.8 : (0.35 + 0.65 * (0.5 + 0.5 * sin(t * 7.5)))
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.recapAICyan, .recapAITeal],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 2.5, height: 16)
                .opacity(pulse)
                .padding(.leading, 2)
        }
    }
}

/// 助手气泡 Markdown 视图：块级排版（段落 / 标题 / 列表 / 引用 / 代码块），
/// 流式 ≥50ms 防抖，结束立即终解析。
public struct AskMarkdownText: View {
    public let source: String
    public var isStreaming: Bool = false

    @State private var blocks: [MarkdownBlock] = []
    @State private var debounceTask: Task<Void, Never>?

    /// 助手正文统一字号（略大于 recapRaw 的 15，长文更易读）。
    private static let bodyFont: Font = .system(size: 16, weight: .regular, design: .default)

    public init(source: String, isStreaming: Bool = false) {
        self.source = source
        self.isStreaming = isStreaming
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                let isLast = (index == blocks.count - 1)
                if isLast && isStreaming {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        blockView(block)
                        StreamingCaret()
                    }
                } else {
                    blockView(block)
                }
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
                .font(Self.bodyFont)
                .lineSpacing(5)

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
                        .font(.system(size: 15, weight: .regular, design: .default))
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

        case .codeBlock(let language, let content):
            if language?.lowercased() == "mermaid" {
                MermaidBlockView(source: content, isStreaming: isStreaming)
            } else {
                Text(content)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.sm + 2)
                    .background(
                        Color.recapInk.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }

        case .thematicBreak:
            Divider()
                .background(Color.recapTea.opacity(0.3))

        case .table(let header, let aligns, let rows):
            tableView(header: header, aligns: aligns, rows: rows)
        }
    }

    @ViewBuilder
    private func bulletRow(marker: String, text: String, monospacedMarker: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm - 2) {
            Text(marker)
                .font(monospacedMarker
                      ? .system(size: 16, weight: .regular, design: .monospaced)
                      : Self.bodyFont)
                .foregroundStyle(Color.recapTea)
            Text(AskMarkdownRenderer.attributed(text))
                .font(Self.bodyFont)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 20, weight: .semibold, design: .default)
        case 2: return .system(size: 18, weight: .semibold, design: .default)
        case 3: return .system(size: 17, weight: .semibold, design: .default)
        default: return .system(size: 16, weight: .semibold, design: .default)
        }
    }

    // MARK: 表格视图

    /// GFM 表格：等宽列网格（每列 `maxWidth: .infinity`，故各行列宽一致、对齐成网格），
    /// 表头加粗 + 圆角边框 + 行间细分隔线，遵循 recapInk/recapTea 中性体系。
    @ViewBuilder
    private func tableView(header: [String], aligns: [MarkdownTableAlign], rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(header.enumerated()), id: \.offset) { idx, cell in
                    let a = align(at: idx, in: aligns)
                    Text(AskMarkdownRenderer.attributedInline(cell))
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .foregroundStyle(Color.recapTea)
                        .multilineTextAlignment(textAlign(a))
                        .frame(maxWidth: .infinity, alignment: frameAlign(a))
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                }
            }
            .background(Color.recapInk.opacity(0.04))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.recapTea.opacity(0.35)).frame(height: 1)
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                        let a = align(at: colIdx, in: aligns)
                        Text(AskMarkdownRenderer.attributedInline(cell))
                            .font(Self.bodyFont)
                            .foregroundStyle(Color.recapInk)
                            .multilineTextAlignment(textAlign(a))
                            .frame(maxWidth: .infinity, alignment: frameAlign(a))
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xs)
                    }
                }
                .overlay(alignment: .bottom) {
                    if rowIdx != rows.count - 1 {
                        Rectangle().fill(Color.recapTea.opacity(0.15)).frame(height: 1)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.recapTea.opacity(0.25), lineWidth: 1)
        )
    }

    private func align(at idx: Int, in aligns: [MarkdownTableAlign]) -> MarkdownTableAlign {
        idx < aligns.count ? aligns[idx] : .left
    }

    private func textAlign(_ a: MarkdownTableAlign) -> TextAlignment {
        switch a { case .left: return .leading; case .center: return .center; case .right: return .trailing }
    }

    private func frameAlign(_ a: MarkdownTableAlign) -> Alignment {
        switch a { case .left: return .leading; case .center: return .center; case .right: return .trailing }
    }

    private func scheduleRender(_ text: String, streaming: Bool) {
        debounceTask?.cancel()
        if streaming {
            // 流式：50ms debounce 合并高频增量解析。
            debounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                blocks = MarkdownBlockParser.parse(text)
            }
        } else {
            // 历史/定稿：错开一帧（~16ms）再 parse，避免对话窗滑入时首屏 N 条消息
            // 同步解析挤掉出现动画（卡顿 + 动效被吞的成因之一）。
            debounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
                blocks = MarkdownBlockParser.parse(text)
            }
        }
    }
}
