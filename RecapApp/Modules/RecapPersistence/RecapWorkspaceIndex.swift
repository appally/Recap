import Foundation
import SwiftData
import RecapModels
import RecapLLM

/// 跨会议只读索引（`@ModelActor`；只回传 Sendable 快照）。
@ModelActor
public actor RecapWorkspaceIndex: AgentWorkspaceQuerying {
    private static let scanCap = 200

    public func searchMeetings(
        query: String,
        excluding: UUID?,
        since: Date?,
        limit: Int
    ) async -> [MeetingCard] {
        let tokens = AgentQueryTokens.tokenize(query)
        guard !tokens.isEmpty else { return [] }
        let capped = min(max(limit, 1), 8)

        var descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.scanCap
        let meetings: [Meeting]
        do {
            meetings = try modelContext.fetch(descriptor)
        } catch {
            return []
        }

        var scored: [(card: MeetingCard, score: Int)] = []
        var scanned = 0
        for meeting in meetings {
            if let excluding, meeting.id == excluding { continue }
            if let since, meeting.startedAt < since { continue }
            scanned += 1

            let fields = rankerFields(from: meeting)
            guard let hit = MeetingCardRanker.score(fields: fields, tokens: tokens) else {
                continue
            }
            let summary = highestVersionSummary(from: meeting)
            var reason = hit.matchReason
            if scanned >= Self.scanCap {
                reason += "（仅扫描最近 \(Self.scanCap) 场）"
            }
            let card = MeetingCard(
                id: meeting.id,
                title: meeting.title,
                startedAt: meeting.startedAt,
                durationSeconds: meeting.durationSeconds,
                tldr: summary.flatMap { s -> String? in
                    let t = s.tldr.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : String(t.prefix(120))
                },
                openQuestionCount: summary?.openQuestions.count ?? 0,
                actionItemCount: meeting.actionItems.count,
                matchReason: reason
            )
            scored.append((card, hit.value))
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(capped)
            .map(\.card)
    }

    public func searchTranscript(
        meetingId: UUID,
        query: String,
        limit: Int
    ) async -> [TranscriptHit] {
        guard let meeting = fetchMeeting(id: meetingId) else { return [] }
        // 单场会才解码 segments（禁止在 searchMeetings 里做这件事）
        let segments = meeting.segments
        let speakers = meeting.speakers
        let capped = min(max(limit, 1), 8)
        return SearchTranscriptTool.search(
            query: query,
            segments: segments,
            speakers: speakers,
            limit: capped
        )
    }

    public func minutes(meetingId: UUID) async -> MeetingSummary? {
        guard let meeting = fetchMeeting(id: meetingId) else { return nil }
        return highestVersionSummary(from: meeting)
    }

    public func meetingLabel(meetingId: UUID) async -> String? {
        guard let meeting = fetchMeeting(id: meetingId) else { return nil }
        let date = meeting.startedAt.formatted(
            Date.FormatStyle()
                .month(.twoDigits)
                .day(.twoDigits)
                .locale(Locale(identifier: "zh_CN"))
        )
        return "\(date) \(meeting.title)"
    }

    public func actionItems(
        meetingId: UUID?,
        openOnly: Bool,
        limit: Int
    ) async -> [ActionItemSnapshot] {
        let capped = min(max(limit, 1), 20)
        if let meetingId {
            guard let meeting = fetchMeeting(id: meetingId) else { return [] }
            return snapshots(
                from: meeting.actionItems,
                meetingTitle: meeting.title,
                openOnly: openOnly,
                limit: capped
            )
        }

        var descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.scanCap
        let meetings = (try? modelContext.fetch(descriptor)) ?? []
        var out: [ActionItemSnapshot] = []
        for meeting in meetings {
            out.append(contentsOf: snapshots(
                from: meeting.actionItems,
                meetingTitle: meeting.title,
                openOnly: openOnly,
                limit: capped - out.count
            ))
            if out.count >= capped { break }
        }
        return Array(out.prefix(capped))
    }

    // MARK: - UI search

    /// 跨会议搜索（面向 UI；独立于 Agent `searchMeetings` 的 limit≤8 契约）。
    ///
    /// 召回策略：ranker 快字段（标题/纪要/待办/笔记）命中的会议 → 收集该场纪要/转写/待办的命中明细。
    /// 纯转写命中（其它字段都不命中）的会议默认不召回——见设计方案「跨会议转写召回权衡」，
    /// 待会议量级与解 segments 实测耗时确认后再决定是否放开全量转写召回。
    public func searchForUI(query: String, limit: Int = 50) async -> [MeetingSearchResult] {
        let tokens = AgentQueryTokens.tokenize(query)
        guard !tokens.isEmpty else { return [] }

        var descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.scanCap
        let meetings = (try? modelContext.fetch(descriptor)) ?? []

        var results: [MeetingSearchResult] = []
        for meeting in meetings {
            let fields = rankerFields(from: meeting)
            guard MeetingCardRanker.score(fields: fields, tokens: tokens) != nil else { continue }
            let hits = collectHits(query: query, tokens: tokens, from: meeting)
            guard !hits.isEmpty else { continue }
            let countByKind = Dictionary(grouping: hits, by: \.kind).mapValues(\.count)
            results.append(MeetingSearchResult(
                meetingId: meeting.id,
                title: meeting.title,
                startedAt: meeting.startedAt,
                durationSeconds: meeting.durationSeconds,
                speakerNames: meeting.speakers.map(\.name),
                hits: hits.sorted { $0.score > $1.score },
                countByKind: countByKind
            ))
        }
        return Array(
            results
                .sorted { ($0.hits.first?.score ?? 0) > ($1.hits.first?.score ?? 0) }
                .prefix(limit)
        )
    }

    /// `Meeting` → ranker 可搜字段（标题/纪要摘要/笔记/决策/遗留/待办）。
    /// `searchMeetings` 与 `searchForUI` 共用，确保 Agent 与 UI 命中口径一致。
    private func rankerFields(from meeting: Meeting) -> MeetingCardRanker.Fields {
        let summary = highestVersionSummary(from: meeting)
        let notes = meeting.outputs
            .filter { $0.kind == .note }
            .compactMap { $0.notePayload }
            .flatMap { [$0.title, $0.body] }
        let actionTasks = meeting.actionItems.flatMap { item -> [String] in
            if let quote = item.evidenceQuote, !quote.isEmpty {
                return [item.task, quote]
            }
            return [item.task]
        }
        return MeetingCardRanker.Fields(
            title: meeting.title,
            tldr: summary?.tldr,
            decisions: summary?.decisions ?? [],
            openQuestions: summary?.openQuestions ?? [],
            actionTasks: actionTasks,
            notes: notes,
            // 人物维度（plan 051）：只进已纠错命名的说话人——默认名无身份语义。
            // search_meetings 与 searchForUI 共用此处，Agent 与 UI 口径自动同步。
            speakers: meeting.speakers.filter { !$0.isUnnamed }.map(\.name)
        )
    }

    /// 收集一场会议的各类型命中明细（标题/纪要/转写/待办）。仅在 ranker 命中场调用。
    private func collectHits(
        query: String,
        tokens: [String],
        from meeting: Meeting
    ) -> [SearchHit] {
        var hits: [SearchHit] = []

        // 标题
        if containsAny(meeting.title, tokens) {
            hits.append(SearchHit(kind: .title, snippet: SearchSnippet.truncated(meeting.title), score: 5))
        }

        // 纪要（tldr / decisions / openQuestions）
        if let summary = highestVersionSummary(from: meeting) {
            if containsAny(summary.tldr, tokens) {
                hits.append(SearchHit(kind: .summary, snippet: SearchSnippet.truncated(summary.tldr), score: 3))
            }
            for d in summary.decisions where containsAny(d, tokens) {
                hits.append(SearchHit(kind: .summary, snippet: "决策：\(SearchSnippet.truncated(d))", score: 2))
            }
            for q in summary.openQuestions where containsAny(q, tokens) {
                hits.append(SearchHit(kind: .summary, snippet: "遗留：\(SearchSnippet.truncated(q))", score: 2))
            }
        }

        // 待办（task + evidenceQuote）
        for item in meeting.actionItems {
            let taskHit = containsAny(item.task, tokens)
            let quote = item.evidenceQuote.flatMap { q -> String? in containsAny(q, tokens) ? q : nil }
            if taskHit || quote != nil {
                let snippet = quote ?? item.task
                hits.append(SearchHit(
                    kind: .actionItem,
                    snippet: SearchSnippet.truncated(snippet),
                    timeAnchor: item.startSeconds,
                    speakerName: item.owner,
                    score: 1
                ))
            }
        }

        // 笔记（NotePayload title + body；修 Phase 1 召回遗漏--原 collectHits 漏收 notes）
        for output in meeting.outputs where output.kind == .note {
            guard let payload = output.notePayload else { continue }
            let combined = payload.title + "\n" + payload.body
            guard containsAny(combined, tokens) else { continue }
            let snippet = containsAny(payload.title, tokens) ? payload.title : payload.body
            hits.append(SearchHit(
                kind: .note,
                snippet: SearchSnippet.truncated(snippet),
                noteTarget: .note(output.id),
                score: 3
            ))
        }

        // 转写（润色稿优先，未润色回退原稿）
        let segments = meeting.polishedSegments.isEmpty ? meeting.segments : meeting.polishedSegments
        let speakers = meeting.speakers
        for th in SearchTranscriptTool.search(query: query, segments: segments, speakers: speakers, limit: 5) {
            hits.append(SearchHit(
                kind: .transcript,
                snippet: SearchSnippet.truncated(th.text),
                timeAnchor: th.startSeconds,
                speakerName: th.speakerName,
                score: 1
            ))
        }

        return hits
    }

    private func containsAny(_ text: String, _ tokens: [String]) -> Bool {
        guard !text.isEmpty else { return false }
        return tokens.contains { text.localizedCaseInsensitiveContains($0) }
    }

    // MARK: - AppIntents 投影

    /// 最近 N 场会议（AppIntents suggestedEntities / 快捷指令候选）。
    public func recentMeetings(limit: Int) async -> [MeetingCard] {
        let capped = min(max(limit, 1), 50)
        var descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = capped
        let meetings = (try? modelContext.fetch(descriptor)) ?? []
        return meetings.map { meetingCard(from: $0, matchReason: "") }
    }

    /// 按 id 批量取会议（AppIntents entities(for:) 解析）。
    public func meetings(for ids: [UUID]) async -> [MeetingCard] {
        guard !ids.isEmpty else { return [] }
        let idList = ids
        var descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { idList.contains($0.id) },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(ids.count, 1)
        let meetings = (try? modelContext.fetch(descriptor)) ?? []
        return meetings.map { meetingCard(from: $0, matchReason: "") }
    }

    private func meetingCard(from meeting: Meeting, matchReason: String) -> MeetingCard {
        let summary = highestVersionSummary(from: meeting)
        let tldr = summary.flatMap { s -> String? in
            let t = s.tldr.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(120))
        }
        return MeetingCard(
            id: meeting.id,
            title: meeting.title,
            startedAt: meeting.startedAt,
            durationSeconds: meeting.durationSeconds,
            tldr: tldr,
            openQuestionCount: summary?.openQuestions.count ?? 0,
            actionItemCount: meeting.actionItems.count,
            matchReason: matchReason
        )
    }

    // MARK: - Helpers

    private func fetchMeeting(id: UUID) -> Meeting? {
        let target = id
        var descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.id == target }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// 取最高 version 的纪要（勿用 `outputs.first(where:)`）。
    private func highestVersionSummary(from meeting: Meeting) -> MeetingSummary? {
        meeting.outputs
            .filter { $0.kind == .summary }
            .max(by: { $0.version < $1.version })?
            .summaryPayload
    }

    private func snapshots(
        from items: [ActionItem],
        meetingTitle: String,
        openOnly: Bool,
        limit: Int
    ) -> [ActionItemSnapshot] {
        guard limit > 0 else { return [] }
        let filtered = items.filter { item in
            if openOnly {
                return item.status != .done && item.status != .dispatched
            }
            return true
        }
        return filtered.prefix(limit).map { item in
            ActionItemSnapshot(
                id: item.id,
                task: item.task,
                owner: item.owner,
                dueText: item.dueText,
                statusRaw: item.status.rawValue,
                meetingTitle: meetingTitle,
                isDispatched: item.isReallyDispatched
            )
        }
    }
}
