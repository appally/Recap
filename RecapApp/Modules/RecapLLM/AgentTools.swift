import Foundation
import NaturalLanguage
import RecapModels

// MARK: - Hits

/// 跨进程稳定的短哈希（FNV-1a 64-bit hex），用于 citation id。
public enum StableContentHash {
    public static func hex64(_ string: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    public static func short(_ string: String, length: Int = 12) -> String {
        let hex = hex64(string)
        return String(hex.prefix(max(4, min(length, hex.count))))
    }
}

public struct TranscriptHit: Sendable, Hashable, Identifiable {
    public var id: String { "\(Int(startSeconds * 1000))-\(StableContentHash.short(text))" }
    public let startSeconds: Double
    public let speakerName: String
    public let text: String

    public init(startSeconds: Double, speakerName: String, text: String) {
        self.startSeconds = startSeconds
        self.speakerName = speakerName
        self.text = text
    }

    public var timeLabel: String {
        let total = Int(startSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

public struct BriefHit: Sendable, Hashable, Identifiable {
    public var id: String
    public let sourceId: UUID
    public let sourceTitle: String
    public let role: BriefRole
    public let text: String

    public init(
        id: String,
        sourceId: UUID,
        sourceTitle: String,
        role: BriefRole,
        text: String
    ) {
        self.id = id
        self.sourceId = sourceId
        self.sourceTitle = sourceTitle
        self.role = role
        self.text = text
    }
}

public struct WebHit: Sendable, Hashable, Identifiable {
    public var id: String { url }
    public let title: String
    public let url: String
    public let content: String

    public init(title: String, url: String, content: String) {
        self.title = title
        self.url = url
        self.content = content
    }
}

// MARK: - Citations

public enum AskCitationKind: String, Sendable, Hashable {
    case transcript
    case brief
    case web
}

public struct AskCitation: Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: AskCitationKind
    public var title: String
    public var snippet: String
    public var startSeconds: Double?
    public var url: String?
    public var briefSourceId: UUID?

    public init(
        id: String,
        kind: AskCitationKind,
        title: String,
        snippet: String,
        startSeconds: Double? = nil,
        url: String? = nil,
        briefSourceId: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.snippet = snippet
        self.startSeconds = startSeconds
        self.url = url
        self.briefSourceId = briefSourceId
    }

    public static func from(_ hit: TranscriptHit) -> AskCitation {
        AskCitation(
            id: "t-\(hit.id)",
            kind: .transcript,
            title: "\(hit.timeLabel) · \(hit.speakerName)",
            snippet: hit.text,
            startSeconds: hit.startSeconds
        )
    }

    public static func from(_ hit: BriefHit) -> AskCitation {
        AskCitation(
            id: "b-\(hit.id)",
            kind: .brief,
            title: "\(hit.role.displayName) · \(hit.sourceTitle)",
            snippet: hit.text,
            briefSourceId: hit.sourceId
        )
    }

    public static func from(_ hit: WebHit) -> AskCitation {
        AskCitation(
            id: "w-\(StableContentHash.short(hit.url))",
            kind: .web,
            title: hit.title.isEmpty ? hit.url : hit.title,
            snippet: hit.content,
            url: hit.url
        )
    }
}

// MARK: - Tokenizer

/// 公开包装，供 Persistence 等模块做会议打分，无需依赖内部实现细节。
public enum AgentQueryTokens {
    public static func tokenize(_ query: String) -> [String] {
        QueryTokenizer.tokenize(query)
    }
}

enum QueryTokenizer {
    private static let stopgrams: Set<String> = [
        "什么", "怎么", "还有", "一下", "我们", "你们", "他们",
        "这个", "那个", "一个", "没有", "不是", "可以", "因为",
        "所以", "如果", "已经", "还是", "就是", "自己",
    ]

    static func tokenize(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var tokens = Set<String>()

        let alpha = trimmed.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        for t in alpha {
            tokens.insert(t.lowercased())
        }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let w = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if w.count >= 2 { tokens.insert(w) }
            return true
        }

        if tokens.isEmpty || (tokens.count == 1 && tokens.contains(trimmed)) {
            for gram in characterNgrams(trimmed, n: 2) where gram.count >= 2 {
                if !stopgrams.contains(gram) {
                    tokens.insert(gram)
                }
            }
        }

        if tokens.isEmpty { return [trimmed] }
        return Array(tokens)
    }

    /// 连续汉字的 n-gram；非 CJK 跳过。
    static func characterNgrams(_ text: String, n: Int) -> [String] {
        guard n >= 2 else { return [] }
        let chars = Array(text).filter { ch in
            ch.unicodeScalars.allSatisfy { scalar in
                let v = scalar.value
                return (v >= 0x4E00 && v <= 0x9FFF)
                    || (v >= 0x3400 && v <= 0x4DBF)
            }
        }
        guard chars.count >= n else { return chars.isEmpty ? [] : [String(chars)] }
        var grams: [String] = []
        for i in 0...(chars.count - n) {
            grams.append(String(chars[i..<(i + n)]))
        }
        return grams
    }
}

// MARK: - Ask retrieval intent（与 AskIntentClassifier 行动意图区分）

public enum AskQueryIntent: Sendable, Equatable {
    case keywordSearch
    case recentWindow(minutes: Double)
    case openItemsFocus
    case fullMeetingRecap
}

public enum AskQueryIntentClassifier {
    public static func classify(_ query: String) -> AskQueryIntent {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["总结到此刻", "刚才讲了啥"].contains(q)
            || q.contains("到此刻")
            || q.contains("刚才讲") {
            return .recentWindow(minutes: 5)
        }
        if q.contains("未决")
            || q == "待办有啥"
            || (q.contains("待办") && q.count <= 10) {
            return .openItemsFocus
        }
        if q.contains("总结这场") || q == "按议程总结" {
            return .fullMeetingRecap
        }
        return .keywordSearch
    }
}

// MARK: - Search transcript

/// 本地转写检索（不经 LLM function call）。
public enum SearchTranscriptTool {
    public static func search(
        query: String,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        limit: Int = 6
    ) -> [TranscriptHit] {
        let tokens = QueryTokenizer.tokenize(query)
        guard !tokens.isEmpty else { return [] }

        struct Scored { let hit: TranscriptHit; let score: Int }
        var scored: [Scored] = []

        for seg in segments {
            let text = seg.text
            guard !text.isEmpty else { continue }
            let score = tokens.reduce(0) { acc, t in
                acc + (text.localizedCaseInsensitiveContains(t) ? 1 : 0)
            }
            guard score > 0 else { continue }
            let name = speakers.first(where: { $0.id == seg.speakerId })?.name ?? "?"
            scored.append(Scored(
                hit: TranscriptHit(startSeconds: seg.startSeconds, speakerName: name, text: text),
                score: score
            ))
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.hit)
    }

    /// 取锚点前 `withinMinutes` 分钟内的片段（按时间升序）。
    public static func recent(
        segments: [TranscriptSegment],
        speakers: [Speaker],
        withinMinutes: Double,
        nowSeconds: Double? = nil,
        limit: Int = 12
    ) -> [TranscriptHit] {
        guard !segments.isEmpty else { return [] }
        let anchor = nowSeconds ?? segments.map(\.endSeconds).max() ?? segments.map(\.startSeconds).max() ?? 0
        let floor = max(0, anchor - withinMinutes * 60)
        let hits: [TranscriptHit] = segments
            .filter { $0.startSeconds >= floor }
            .sorted { $0.startSeconds < $1.startSeconds }
            .prefix(limit)
            .map { seg in
                let name = speakers.first(where: { $0.id == seg.speakerId })?.name ?? "?"
                return TranscriptHit(
                    startSeconds: seg.startSeconds,
                    speakerName: name,
                    text: seg.text
                )
            }
        return Array(hits)
    }
}

// MARK: - Search brief (L3)

/// 会前底稿原文按需检索（不经 LLM function call）。
public enum SearchBriefTool {
    public static let maxChunkChars = 500
    public static let chunkOverlap = 80
    public static let maxHitChars = 400

    public static func search(
        query: String,
        sources: [BriefSource],
        limit: Int = 4
    ) -> [BriefHit] {
        let tokens = QueryTokenizer.tokenize(query)
        guard !tokens.isEmpty else { return [] }

        struct Scored { let hit: BriefHit; let score: Int }
        var scored: [Scored] = []

        for source in sources {
            guard source.parseStatus != .failed else { continue }
            guard let raw = source.rawText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }

            let chunks = chunkText(raw, maxChars: maxChunkChars, overlap: chunkOverlap)
            for (idx, chunk) in chunks.enumerated() {
                let score = tokens.reduce(0) { acc, t in
                    acc + (chunk.localizedCaseInsensitiveContains(t) ? 1 : 0)
                }
                guard score > 0 else { continue }
                let snippet = String(chunk.prefix(maxHitChars))
                scored.append(Scored(
                    hit: BriefHit(
                        id: "\(source.id.uuidString)-\(idx)",
                        sourceId: source.id,
                        sourceTitle: source.title.isEmpty ? source.role.displayName : source.title,
                        role: source.role,
                        text: snippet
                    ),
                    score: score
                ))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.hit)
    }

    /// 按固定窗口切片；优先在换行处切开。
    public static func chunkText(_ text: String, maxChars: Int, overlap: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxChars else { return [trimmed] }

        var chunks: [String] = []
        var start = trimmed.startIndex
        while start < trimmed.endIndex {
            let remaining = trimmed.distance(from: start, to: trimmed.endIndex)
            let take = min(maxChars, remaining)
            var end = trimmed.index(start, offsetBy: take)
            if take == maxChars, end < trimmed.endIndex {
                let window = trimmed[start..<end]
                if let nl = window.lastIndex(of: "\n") {
                    let after = trimmed.index(after: nl)
                    if after > start { end = after }
                }
            }
            let piece = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            if end >= trimmed.endIndex { break }
            let back = min(overlap, trimmed.distance(from: start, to: end))
            let next = trimmed.index(end, offsetBy: -back)
            start = next > start ? next : end
        }
        return chunks
    }
}

// MARK: - Web routing

/// 是否应发起联网检索（开关开 + 外网意图 / 关键字 / 本地全空）。
/// 会内专用问法（总结到此刻等）不触发；外网事实题不因本地弱 hit 被否决。
public enum AskWebRouter {
    public static func needsWeb(
        query: String,
        webEnabled: Bool,
        localHitCount: Int
    ) -> Bool {
        guard webEnabled else { return false }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }

        if isMeetingInternalOnly(q) {
            return false
        }

        if hasWebKeyword(q) || looksLikeExternalFact(q) {
            return true
        }
        return localHitCount == 0
    }

    public static func hasWebKeyword(_ query: String) -> Bool {
        let q = query.lowercased()
        let keys = [
            "查一下", "查一查", "搜索", "联网", "搜一下", "搜搜",
            "google", "什么是", "网上", "wiki", "维基", "github",
        ]
        return keys.contains { q.contains($0) }
    }

    /// 估值/官网/竞品等外网事实题（即使转写里提过实体名也应搜）。
    public static func looksLikeExternalFact(_ query: String) -> Bool {
        let q = query.lowercased()
        let markers = [
            "最新", "官网", "竞品", "股价", "市值", "估值", "汇率",
            "政策", "新闻", "融资", "财报", "对比", "公开",
            "行业排名", "市场份额", "美元", "发布会",
        ]
        return markers.contains { q.contains($0) }
    }

    /// 会内芯片 / 专属问法：不应误触联网。
    public static func isMeetingInternalOnly(_ query: String) -> Bool {
        if hasWebKeyword(query) || looksLikeExternalFact(query) {
            return false
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let internals = [
            "到此刻", "刚才讲", "总结这场", "按议程",
            "待办有啥", "还有什么未决", "本场转写", "本场会议",
            "会上说", "纪要里",
        ]
        return internals.contains { q.contains($0) }
    }
}

// MARK: - Intent

public enum AskIntent: Sendable, Equatable {
    case answerQuestion
    case dispatchReminders
    case draftDocument(hint: String)
}

@available(*, deprecated, message: "新路径用 create_reminders 工具；此分类器仅服务旧兜底")
public enum AskIntentClassifier {
    public static func classify(_ query: String) -> AskIntent {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q == "帮我分发待办" { return .dispatchReminders }
        if q.contains("分发") && (q.contains("待办") || q.contains("提醒")) {
            return .dispatchReminders
        }
        if q.contains("起草") || q.contains("写一封") || q.contains("草稿") {
            return .draftDocument(hint: q)
        }
        return .answerQuestion
    }
}
