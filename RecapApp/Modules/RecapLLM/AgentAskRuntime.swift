import Foundation
import RecapModels

/// Ask 编排：本地转写 + 底稿检索 →（可选）联网 → 再生成。
/// 避免 DeepSeek 强制 multi tool_choice。
public enum AgentAskRuntime {
    public struct AnswerContext: Sendable {
        public let citations: [AskCitation]
        public let system: String
        public let user: String
        public let localHitCount: Int
        public let webAttempted: Bool

        /// 兼容旧字段名：仅转写命中。
        public var sources: [TranscriptHit] {
            citations.compactMap { c in
                guard c.kind == .transcript, let start = c.startSeconds else { return nil }
                let speaker = c.title.split(separator: "·").last.map {
                    String($0).trimmingCharacters(in: .whitespaces)
                } ?? "?"
                return TranscriptHit(startSeconds: start, speakerName: speaker, text: c.snippet)
            }
        }

        public init(
            citations: [AskCitation],
            system: String,
            user: String,
            localHitCount: Int,
            webAttempted: Bool = false
        ) {
            self.citations = citations
            self.system = system
            self.user = user
            self.localHitCount = localHitCount
            self.webAttempted = webAttempted
        }
    }

    public static func prepareLocal(
        query: String,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        fallbackTranscript: String,
        briefSummary: String? = nil,
        briefSources: [BriefSource] = [],
        minutesBlock: String? = nil,
        actionItemsBlock: String? = nil,
        momentsSummary: String? = nil,
        handwritingSummary: String? = nil,
        phase: MeetingPhase = .review,
        retrievalQuery: String? = nil,
        meSpeakerLabel: String? = nil,
        userProfile: UserProfile? = nil
    ) -> AnswerContext {
        let intent = AskQueryIntentClassifier.classify(query)
        let searchQuery = {
            let alt = retrievalQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return alt.isEmpty ? query : alt
        }()
        let hasDossier = !(minutesBlock ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(actionItemsBlock ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let transcriptHits: [TranscriptHit]
        switch intent {
        case .recentWindow(let minutes):
            transcriptHits = SearchTranscriptTool.recent(
                segments: segments,
                speakers: speakers,
                withinMinutes: minutes
            )
        case .fullMeetingRecap:
            if hasDossier {
                transcriptHits = SearchTranscriptTool.search(
                    query: searchQuery,
                    segments: segments,
                    speakers: speakers,
                    limit: 4
                )
            } else {
                transcriptHits = SearchTranscriptTool.recent(
                    segments: segments,
                    speakers: speakers,
                    withinMinutes: 15,
                    limit: 12
                )
            }
        case .openItemsFocus, .keywordSearch:
            transcriptHits = SearchTranscriptTool.search(
                query: searchQuery,
                segments: segments,
                speakers: speakers,
                limit: 6
            )
        }

        let briefHits = SearchBriefTool.search(
            query: searchQuery,
            sources: briefSources,
            limit: 4
        )

        let transcriptBlock: String
        if transcriptHits.isEmpty {
            if intent == .openItemsFocus, hasDossier {
                transcriptBlock = "（请优先依据【本场待办】与【本场纪要】中的遗留问题回答。）"
            } else if case .recentWindow = intent, segments.isEmpty {
                transcriptBlock = "（暂无转写）"
            } else {
                let capped = MinutesPipeline.cappedTranscript(fallbackTranscript, maxChars: 6_000)
                transcriptBlock = capped.isEmpty ? "（暂无转写）" : capped
            }
        } else {
            transcriptBlock = transcriptHits.map { hit in
                "[\(hit.timeLabel) \(hit.speakerName)] \(hit.text)"
            }.joined(separator: "\n")
        }

        let briefEvidenceBlock: String = briefHits.isEmpty
            ? ""
            : briefHits.map { hit in
                "[\(hit.role.displayName) · \(hit.sourceTitle)] \(hit.text)"
            }.joined(separator: "\n")

        let brief = (briefSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let briefCoordBlock = brief.isEmpty ? "" : String(brief.prefix(1_800))
        let minutes = minutesBlock?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let actions = actionItemsBlock?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let phaseHint: String
        switch phase {
        case .live, .processing:
            phaseHint = "当前为会中；优先依据【检索片段】中的最近转写。"
        case .review:
            phaseHint = "当前为会后；若有【本场纪要】【本场待办】可优先用于结构问答。"
        }

        let system = """
        你是 Recap 会议助手。根据【会前底稿】（结构坐标系）、【本场纪要】【本场待办】（若有）、【检索片段】（本场转写）、【底稿片段】（议案/材料原文）与【联网摘录】（若有）回答。
        \(phaseHint)
        事实优先级：转写 > 纪要/待办 > 底稿片段 > 网页。冲突时标明来源，不要编造。
        涉及原话/数字冲突时以【检索片段】转写为准。
        网页内容只能依据【联网摘录】，禁止编造 URL。
        用简体中文，简洁，像同事口头答复。涉及转写事实时用 mm:ss 标时间。不要开场白。
        """

        var userParts: [String] = []
        // 用户身份档案（全局；与技能路径 makeUserPrompt 同构，user-payload 侧·caching 安全）。
        if let profile = userProfile?.promptSummary {
            userParts.append(profile)
        }
        if !briefCoordBlock.isEmpty {
            userParts.append("【会前底稿】\n\(briefCoordBlock)")
        }
        if !minutes.isEmpty {
            userParts.append("【本场纪要】\n\(minutes)")
        }
        if !actions.isEmpty {
            userParts.append("【本场待办】\n\(actions)")
        }
        // 会中标记（照片/想法）——补现有缺口：此前 chat 上下文未注入 moments。
        if let moments = momentsSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !moments.isEmpty {
            userParts.append("【会中标记（照片/想法）】\n\(moments)")
        }
        // 会中手写笔记（Apple Pencil 识别文字）。
        if let handwriting = handwritingSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !handwriting.isEmpty {
            userParts.append("【会中手写笔记】\n\(handwriting)")
        }
        // 「你的发言」身份标记（与技能路径同构；标记我/单发言人可解析时产出，让"我的待办/我的承诺"可答）。
        if let meLabel = meSpeakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !meLabel.isEmpty {
            userParts.append("【你的发言】本场转写中「\(meLabel)」是你（用户本人）的发言。")
        }
        userParts.append("【检索片段】\n\(transcriptBlock)")
        if !briefEvidenceBlock.isEmpty {
            userParts.append("【底稿片段】\n\(briefEvidenceBlock)")
        }
        userParts.append("【问题】\n\(query)")

        var citations: [AskCitation] = []
        citations.append(contentsOf: transcriptHits.map(AskCitation.from))
        citations.append(contentsOf: briefHits.map(AskCitation.from))

        return AnswerContext(
            citations: citations,
            system: system,
            user: userParts.joined(separator: "\n\n"),
            localHitCount: transcriptHits.count + briefHits.count,
            webAttempted: false
        )
    }

    public static func mergeWeb(into local: AnswerContext, webHits: [WebHit], query: String) -> AnswerContext {
        guard !webHits.isEmpty else { return local }

        let webBlock = webHits.map { hit in
            "- \(hit.title)\n  \(hit.url)\n  \(hit.content)"
        }.joined(separator: "\n")

        var user = local.user
        if let range = user.range(of: "【问题】") {
            user.insert(contentsOf: "【联网摘录】\n\(webBlock)\n\n", at: range.lowerBound)
        } else {
            user += "\n\n【联网摘录】\n\(webBlock)"
        }

        var citations = local.citations
        citations.append(contentsOf: webHits.map(AskCitation.from))

        return AnswerContext(
            citations: citations,
            system: local.system,
            user: user,
            localHitCount: local.localHitCount,
            webAttempted: true
        )
    }

    /// 兼容旧调用：仅转写 + 底稿摘要。
    public static func prepareAnswer(
        query: String,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        fallbackTranscript: String,
        briefSummary: String? = nil,
        briefSources: [BriefSource] = [],
        minutesBlock: String? = nil,
        actionItemsBlock: String? = nil,
        momentsSummary: String? = nil,
        handwritingSummary: String? = nil,
        phase: MeetingPhase = .review,
        retrievalQuery: String? = nil,
        meSpeakerLabel: String? = nil,
        userProfile: UserProfile? = nil
    ) -> AnswerContext {
        prepareLocal(
            query: query,
            segments: segments,
            speakers: speakers,
            fallbackTranscript: fallbackTranscript,
            briefSummary: briefSummary,
            briefSources: briefSources,
            minutesBlock: minutesBlock,
            actionItemsBlock: actionItemsBlock,
            momentsSummary: momentsSummary,
            handwritingSummary: handwritingSummary,
            phase: phase,
            retrievalQuery: retrievalQuery,
            meSpeakerLabel: meSpeakerLabel,
            userProfile: userProfile
        )
    }
}
