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

            let summary = highestVersionSummary(from: meeting)
            let fields = MeetingCardRanker.Fields(
                title: meeting.title,
                tldr: summary?.tldr,
                decisions: summary?.decisions ?? [],
                openQuestions: summary?.openQuestions ?? [],
                actionTasks: meeting.actionItems.map(\.task)
            )
            guard let hit = MeetingCardRanker.score(fields: fields, tokens: tokens) else {
                continue
            }
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
