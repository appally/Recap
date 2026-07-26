import Foundation
import RecapModels

/// 按会中/会后上下文生成「可能想问」的 tips（短、可点、不编造会外事实）。
public enum AskSuggestionTips {

    public static func make(
        phase: MeetingPhase,
        summary: MeetingSummary?,
        actionItems: [ActionItem],
        briefOpenItems: [String] = [],
        recentTranscript: String = "",
        hasBrief: Bool = false
    ) -> [String] {
        var tips: [String] = []
        switch phase {
        case .live, .processing:
            tips.append(contentsOf: liveTips(
                briefOpenItems: briefOpenItems,
                recentTranscript: recentTranscript,
                hasBrief: hasBrief,
                processing: phase == .processing
            ))
        case .review:
            tips.append(contentsOf: reviewTips(
                summary: summary,
                actionItems: actionItems,
                hasBrief: hasBrief
            ))
        }
        return dedupe(tips, limit: 5)
    }

    // MARK: - Live

    private static func liveTips(
        briefOpenItems: [String],
        recentTranscript: String,
        hasBrief: Bool,
        processing: Bool
    ) -> [String] {
        if processing {
            return ["还要多久", "先给我要点"]
        }
        var tips: [String] = ["总结到此刻"]
        if hasBrief {
            tips.append("第三项议程讲了啥")
        }
        for item in briefOpenItems.prefix(2) {
            let short = clip(item, max: 14)
            guard !short.isEmpty else { continue }
            tips.append("「\(short)」有结论吗")
        }
        if let snippet = recentSnippet(from: recentTranscript) {
            tips.append("「\(snippet)」是什么意思")
        }
        tips.append("刚才拍板了什么")
        tips.append("有新的待办吗")
        return tips
    }

    // MARK: - Review

    private static func reviewTips(
        summary: MeetingSummary?,
        actionItems: [ActionItem],
        hasBrief: Bool
    ) -> [String] {
        var tips: [String] = [hasBrief ? "按议程总结" : "总结这场会议"]
        if let summary {
            for q in summary.openQuestions.prefix(2) {
                let short = clip(q, max: 18)
                if !short.isEmpty { tips.append(short) }
            }
            if !summary.decisions.isEmpty {
                tips.append("关键决议有哪些")
            }
            tips.append("把纪要压短一点")
        }
        let openTodos = actionItems.filter { $0.status != .done }
        if !openTodos.isEmpty {
            tips.append("待办都分给谁了")
            tips.append("帮我分发待办")
        } else {
            tips.append("还有什么未决")
        }
        return tips
    }

    // MARK: - Helpers

    private static func recentSnippet(from transcript: String) -> String? {
        let lines = transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = lines.suffix(3).last else { return nil }
        // 去掉「说话人：」前缀
        let body: String
        if let idx = last.firstIndex(of: "：") {
            body = String(last[last.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        } else if let idx = last.firstIndex(of: ":") {
            body = String(last[last.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        } else {
            body = last
        }
        let clipped = clip(body, max: 12)
        return clipped.count >= 4 ? clipped : nil
    }

    private static func clip(_ text: String, max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return String(t.prefix(max)) + "…"
    }

    private static func dedupe(_ tips: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tip in tips {
            let key = tip.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(key)
            if out.count >= limit { break }
        }
        return out
    }
}
