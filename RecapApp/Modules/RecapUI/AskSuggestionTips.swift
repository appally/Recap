import Foundation
import RecapModels

/// 「可能想问」chips 的 L1 规则层：按 `AskStage` 五态生成短、可点、不编造会外事实的提示问题。
///
/// 瞬时、纯函数、零成本，作为 `AgentInvokeSheet` 打开时的打底 chips；
/// L2 LLM 动态层（`SuggestedQuestionsGenerator`）异步返回更高定制的问题后，
/// 由调用方决定是否替换。本层永远保证每态都有合理问题，即使 L2 失败也不空白。
public enum AskSuggestionTips {

    public static func make(
        stage: AskStage,
        summary: MeetingSummary?,
        actionItems: [ActionItem],
        agendaTitles: [String] = [],
        briefOpenItems: [String] = [],
        linkedMeetingTitle: String? = nil,
        recentTranscript: String = "",
        hasBrief: Bool = false
    ) -> [String] {
        var tips: [String] = []
        switch stage {
        case .preMeeting:
            tips.append(contentsOf: preMeetingTips(
                agendaTitles: agendaTitles,
                linkedTitle: linkedMeetingTitle,
                hasBrief: hasBrief
            ))
        case .liveRecording:
            tips.append(contentsOf: liveRecordingTips(
                briefOpenItems: briefOpenItems,
                transcript: recentTranscript,
                hasBrief: hasBrief
            ))
        case .livePaused:
            tips.append(contentsOf: livePausedTips(briefOpenItems: briefOpenItems))
        case .processing:
            tips.append(contentsOf: ["还要多久", "先给我要点", "有看到待办吗"])
        case .review:
            tips.append(contentsOf: reviewTips(
                summary: summary,
                actionItems: actionItems,
                hasBrief: hasBrief
            ))
        }
        return dedupe(tips, limit: 5)
    }

    // MARK: - Pre-meeting（准备向，会议前·启动台）

    private static func preMeetingTips(
        agendaTitles: [String],
        linkedTitle: String?,
        hasBrief: Bool
    ) -> [String] {
        var tips: [String] = ["这场想达成什么", "先过一下议程"]
        if let first = agendaTitles.first(where: { !$0.isEmpty }) {
            tips.append("「\(clip(first, max: 12))」要准备啥")
        }
        if let linkedTitle {
            tips.append("「\(clip(linkedTitle, max: 10))」遗留对接")
        }
        if hasBrief {
            tips.append("资料里有几个要点")
        }
        return tips
    }

    // MARK: - Live recording（补课向，会议中·录音中）

    private static func liveRecordingTips(
        briefOpenItems: [String],
        transcript: String,
        hasBrief: Bool
    ) -> [String] {
        var tips: [String] = ["总结到此刻"]
        if hasBrief {
            tips.append("第三项议程讲了啥")
        }
        for item in briefOpenItems.prefix(2) {
            let short = clip(item, max: 14)
            guard !short.isEmpty else { continue }
            tips.append("「\(short)」有结论吗")
        }
        if let snippet = recentSnippet(from: transcript) {
            tips.append("「\(snippet)」是什么意思")
        }
        tips.append("刚才拍板了什么")
        tips.append("有新的待办吗")
        return tips
    }

    // MARK: - Live paused（拍板向，会议中·暂停/决策台）

    private static func livePausedTips(briefOpenItems: [String]) -> [String] {
        var tips: [String] = ["到目前为止的要点", "刚才拍板了什么"]
        if let first = briefOpenItems.first(where: { !$0.isEmpty }) {
            tips.append("「\(clip(first, max: 14))」定了吗")
        }
        tips.append("下一步待办")
        return tips
    }

    // MARK: - Review（行动/分析向，会后）

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
