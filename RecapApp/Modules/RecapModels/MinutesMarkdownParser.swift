import Foundation

/// 将模型输出的纪要 Markdown 拆成短标题 + `MeetingSummary`（可单测）。
public enum MinutesMarkdownParser {
    public struct Parsed: Sendable {
        public var title: String?
        public var summary: MeetingSummary

        public init(title: String?, summary: MeetingSummary) {
            self.title = title
            self.summary = summary
        }
    }

    private static let tldrMaxChars = 220

    public static func parse(_ markdown: String) -> Parsed {
        let title = extractTitle(from: markdown)
        let decisions = extractBullets(from: markdown, headingHints: ["关键决策"])
        let openQuestions = extractBullets(from: markdown, headingHints: ["遗留问题", "未决问题", "未决"])
        let topics = extractTopics(from: markdown)
        let tldr = sanitizeTldr(extractTheme(from: markdown))
        return Parsed(
            title: title,
            summary: MeetingSummary(
                tldr: tldr,
                topics: topics,
                decisions: decisions,
                openQuestions: openQuestions
            )
        )
    }

    /// 纠正把整篇 Markdown / 套话写进 tldr 的脏数据。
    public static func sanitizedSummary(_ summary: MeetingSummary) -> MeetingSummary {
        let tldr = sanitizeTldr(summary.tldr)
        if looksLikeFullMinutes(tldr) {
            let reparsed = parse(tldr)
            return MeetingSummary(
                tldr: reparsed.summary.tldr,
                topics: summary.topics.isEmpty ? reparsed.summary.topics : summary.topics,
                decisions: summary.decisions.isEmpty ? reparsed.summary.decisions : summary.decisions,
                openQuestions: summary.openQuestions.isEmpty
                    ? reparsed.summary.openQuestions : summary.openQuestions
            )
        }
        return MeetingSummary(
            tldr: tldr,
            topics: summary.topics,
            decisions: summary.decisions,
            openQuestions: summary.openQuestions
        )
    }

    // MARK: - Internals

    private static func looksLikeFullMinutes(_ text: String) -> Bool {
        let markers = ["核心摘要", "议题纪要", "讨论要点", "关键决策", "遗留问题", "\n#", "\n##"]
        return markers.contains(where: { text.contains($0) })
    }

    public static func sanitizeTldr(_ text: String) -> String {
        let bannedPrefixes = [
            "以下是", "下面是", "根据转写", "根据会议", "本次会议纪要",
            "会议纪要如下", "纪要如下", "旁白：", "旁白:", "【旁白】",
        ]
        let sectionMarkers = [
            "核心摘要", "议题纪要", "对照议程", "讨论要点",
            "关键决策", "遗留问题", "未决问题",
        ]
        var lines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") { continue }
            if sectionMarkers.contains(where: { trimmed.contains($0) }) { break }
            if bannedPrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("•") { continue }
            lines.append(trimmed)
        }
        return truncateAtSentence(lines.joined(separator: ""), maxChars: tldrMaxChars)
    }

    private static func extractTitle(from markdown: String) -> String? {
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else {
                if trimmed.isEmpty { continue }
                return nil
            }
            // 只要一级标题；`##` 是分节
            let hashCount = trimmed.prefix(while: { $0 == "#" }).count
            guard hashCount == 1 else { continue }
            let title = trimmed.drop(while: { $0 == "#" || $0 == " " })
            let refined = Meeting.refineTitle(String(title))
            return refined.isEmpty ? nil : refined
        }
        return nil
    }

    /// 优先 `## 核心摘要` 段；否则取标题下首段陈述句。硬上限 220 字，尽量在句号截断。
    private static func extractTheme(from markdown: String) -> String {
        if let fromSection = extractSectionProse(
            from: markdown,
            headingHints: ["核心摘要"]
        ), !fromSection.isEmpty {
            return truncateAtSentence(fromSection, maxChars: tldrMaxChars)
        }

        let sectionMarkers = [
            "核心摘要", "议题纪要", "对照议程", "讨论要点",
            "关键决策", "遗留问题", "未决问题", "决策",
        ]
        var parts: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                if !parts.isEmpty { break }
                continue
            }
            if trimmed.hasPrefix("#") {
                if !parts.isEmpty { break }
                continue
            }
            if sectionMarkers.contains(where: { trimmed.contains($0) }) { break }
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("•") {
                if !parts.isEmpty { break }
                continue
            }
            parts.append(trimmed)
            if parts.joined().count >= tldrMaxChars { break }
        }
        return truncateAtSentence(parts.joined(separator: ""), maxChars: tldrMaxChars)
    }

    private static func extractTopics(from markdown: String) -> [MeetingTopic] {
        let fromH3 = extractH3Topics(from: markdown, underHeadings: ["议题纪要", "对照议程"])
        if !fromH3.isEmpty {
            return fromH3
        }
        // 旧版「对照议程」仅有 `- 标题：结论` 列表
        let flat = extractBullets(from: markdown, headingHints: ["对照议程", "议题纪要"])
        return flat.compactMap { bullet -> MeetingTopic? in
            let parts = bullet.split(separator: "：", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let title = parts[0].trimmingCharacters(in: .whitespaces)
                let body = parts[1].trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { return nil }
                return MeetingTopic(title: title, bullets: body.isEmpty ? [] : [body])
            }
            let colon = bullet.split(separator: ":", maxSplits: 1).map(String.init)
            if colon.count == 2 {
                let title = colon[0].trimmingCharacters(in: .whitespaces)
                let body = colon[1].trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { return nil }
                return MeetingTopic(title: title, bullets: body.isEmpty ? [] : [body])
            }
            return MeetingTopic(title: bullet, bullets: [])
        }
    }

    private static func extractH3Topics(from markdown: String, underHeadings: [String]) -> [MeetingTopic] {
        let lines = markdown.components(separatedBy: .newlines)
        var inParent = false
        var topics: [MeetingTopic] = []
        var currentTitle: String?
        var currentBullets: [String] = []

        func flush() {
            guard let title = currentTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
                currentTitle = nil
                currentBullets = []
                return
            }
            topics.append(MeetingTopic(title: title, bullets: currentBullets))
            currentTitle = nil
            currentBullets = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isSectionHeading(trimmed, hints: underHeadings) {
                inParent = true
                flush()
                continue
            }
            guard inParent else { continue }

            if isH2Heading(trimmed), !isSectionHeading(trimmed, hints: underHeadings) {
                flush()
                break
            }

            if isH3Heading(trimmed) {
                flush()
                currentTitle = h3Title(trimmed)
                continue
            }

            if currentTitle != nil {
                if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                    let item = trimmed.drop(while: { "*•- ".contains($0) })
                    if !item.isEmpty { currentBullets.append(String(item)) }
                }
            }
        }
        flush()
        return topics
    }

    private static func extractSectionProse(from markdown: String, headingHints: [String]) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        var collecting = false
        var parts: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isSectionHeading(trimmed, hints: headingHints) {
                collecting = true
                continue
            }
            guard collecting else { continue }
            if isH2Heading(trimmed) { break }
            if trimmed.isEmpty {
                if !parts.isEmpty { break }
                continue
            }
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("•") { break }
            if trimmed.hasPrefix("#") { break }
            parts.append(trimmed)
            if parts.joined().count >= tldrMaxChars { break }
        }
        let joined = parts.joined(separator: "")
        return joined.isEmpty ? nil : joined
    }

    private static func extractBullets(from markdown: String, headingHints: [String]) -> [String] {
        let lines = markdown.components(separatedBy: .newlines)
        var collecting = false
        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isSectionHeading(trimmed, hints: headingHints) {
                collecting = true
                continue
            }
            if collecting {
                if isH2Heading(trimmed) { break }
                if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                    let item = trimmed.drop(while: { "*•- ".contains($0) })
                    if !item.isEmpty { result.append(String(item)) }
                } else if trimmed.isEmpty, !result.isEmpty {
                    break
                }
            }
        }
        return result
    }

    private static func isSectionHeading(_ trimmed: String, hints: [String]) -> Bool {
        let body = String(trimmed.drop(while: { $0 == "#" || $0 == " " }))
        guard hints.contains(where: { body == $0 || body.hasPrefix($0) }) else { return false }
        // `### 议题` 不算 H2 分节；裸标题或 `##` 才算
        if trimmed.hasPrefix("###") { return false }
        return trimmed.hasPrefix("##") || !trimmed.hasPrefix("#")
    }

    private static func isH2Heading(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("##") && !trimmed.hasPrefix("###")
    }

    private static func isH3Heading(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("###") && !trimmed.hasPrefix("####")
    }

    private static func h3Title(_ trimmed: String) -> String {
        String(trimmed.drop(while: { $0 == "#" || $0 == " " }))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func truncateAtSentence(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let prefix = String(text.prefix(maxChars))
        let delimiters: [Character] = ["。", "！", "？", ".", "!", "?"]
        if let idx = prefix.lastIndex(where: { delimiters.contains($0) }) {
            let cut = String(prefix[...idx])
            if cut.count >= maxChars / 3 { return cut }
        }
        return prefix
    }
}
