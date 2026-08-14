import Foundation

/// `search_meetings` 打分（纯函数；不碰转写 blob）。
public enum MeetingCardRanker {
    public struct Fields: Sendable {
        public var title: String
        public var tldr: String?
        public var decisions: [String]
        public var openQuestions: [String]
        public var actionTasks: [String]
        /// 笔记层产物（对外纪要/邮件/周报等的 title + body）。
        public var notes: [String]
        /// 已命名的说话人（plan 051：人物维度召回——「搜人名找会议」；默认名过滤在组装侧）。
        public var speakers: [String]

        public init(
            title: String,
            tldr: String? = nil,
            decisions: [String] = [],
            openQuestions: [String] = [],
            actionTasks: [String] = [],
            notes: [String] = [],
            speakers: [String] = []
        ) {
            self.title = title
            self.tldr = tldr
            self.decisions = decisions
            self.openQuestions = openQuestions
            self.actionTasks = actionTasks
            self.notes = notes
            self.speakers = speakers
        }
    }

    public struct Score: Sendable, Equatable {
        public var value: Int
        public var matchReason: String
    }

    /// 无命中返回 nil。
    public static func score(fields: Fields, tokens: [String]) -> Score? {
        guard !tokens.isEmpty else { return nil }
        var reasons: [String] = []
        var total = 0

        let titleHits = countHits(in: fields.title, tokens: tokens)
        if titleHits > 0 {
            total += titleHits * 5
            reasons.append("标题")
        }
        if let tldr = fields.tldr {
            let h = countHits(in: tldr, tokens: tokens)
            if h > 0 {
                total += h * 3
                reasons.append("纪要摘要")
            }
        }
        let noteText = fields.notes.joined(separator: "\n")
        let noteHits = countHits(in: noteText, tokens: tokens)
        if noteHits > 0 {
            total += noteHits * 3
            reasons.append("笔记")
        }
        let decisionText = fields.decisions.joined(separator: "\n")
        let dHits = countHits(in: decisionText, tokens: tokens)
        if dHits > 0 {
            total += dHits * 2
            reasons.append("决策")
        }
        let openText = fields.openQuestions.joined(separator: "\n")
        let oHits = countHits(in: openText, tokens: tokens)
        if oHits > 0 {
            total += oHits * 2
            reasons.append("遗留")
        }
        let taskText = fields.actionTasks.joined(separator: "\n")
        let aHits = countHits(in: taskText, tokens: tokens)
        if aHits > 0 {
            total += aHits
            reasons.append("待办")
        }
        // 人物命中权重同决策/遗留（×2）：搜人名是强意图（「这个客户的会」），
        // 但说话人名只在纠错命名后存在，命中即高置信（plan 051）。
        let speakerText = fields.speakers.joined(separator: "\n")
        let sHits = countHits(in: speakerText, tokens: tokens)
        if sHits > 0 {
            total += sHits * 2
            reasons.append("说话人")
        }

        guard total > 0 else { return nil }
        let reason = reasons.isEmpty ? "关键词" : reasons.joined(separator: "、")
        return Score(value: total, matchReason: reason)
    }

    private static func countHits(in text: String, tokens: [String]) -> Int {
        guard !text.isEmpty else { return 0 }
        return tokens.reduce(0) { acc, t in
            acc + (text.localizedCaseInsensitiveContains(t) ? 1 : 0)
        }
    }
}
