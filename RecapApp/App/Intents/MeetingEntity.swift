import AppIntents
import CoreSpotlight
import Foundation
import RecapModels
import RecapPersistence

// ─────────────────────────────────────────────────────────────────────────────
// App Intents 投影（D1）：会议进 Spotlight / 快捷指令 / Siri。
// AppEntity 必须是 Sendable 值类型；SwiftData @Model 非 Sendable，故经 RecapWorkspaceIndex
// （@ModelActor）读出 MeetingCard 快照后投影成此 struct。IndexedEntity 让会议进系统搜索索引。
// ─────────────────────────────────────────────────────────────────────────────

struct MeetingEntity: AppEntity, IndexedEntity {
    let id: UUID
    let title: String
    let startedAt: Date
    let durationSeconds: Double
    let tldr: String?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "会议"
    var displayRepresentation: DisplayRepresentation {
        let date = startedAt.formatted(
            .dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN"))
        )
        var subtitle = date
        if let tldr, !tldr.isEmpty { subtitle += " · \(tldr)" }
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    /// IndexedEntity：系统据此把会议建进 Spotlight 索引（下拉搜索可命中）。
    var attributeSet: CSSearchableItemAttributeSet {
        let attr = CSSearchableItemAttributeSet(itemContentType: "public.text")
        attr.identifier = id.uuidString
        attr.title = title
        attr.contentDescription = tldr
        attr.startDate = startedAt
        attr.contentCreationDate = startedAt
        return attr
    }

    static let defaultQuery = MeetingEntityQuery()

    init(card: MeetingCard) {
        id = card.id
        title = card.title
        startedAt = card.startedAt
        durationSeconds = card.durationSeconds
        tldr = card.tldr
    }
}

/// 会议解析器：经 RecapWorkspaceIndex（@ModelActor）读 SwiftData，回传 Sendable 投影。
struct MeetingEntityQuery: EntityQuery {

    func entities(for identifiers: [UUID]) async throws -> [MeetingEntity] {
        guard let container = RecapDataContainer.shared else { return [] }
        let index = RecapWorkspaceIndex(modelContainer: container)
        return await index.meetings(for: identifiers).map(MeetingEntity.init)
    }

    func suggestedEntities() async throws -> [MeetingEntity] {
        guard let container = RecapDataContainer.shared else { return [] }
        let index = RecapWorkspaceIndex(modelContainer: container)
        return await index.recentMeetings(limit: 20).map(MeetingEntity.init)
    }

    /// Spotlight / Siri 串检索入口（IndexedEntity 命中后系统会用它补全）。
    func entities(matching string: String) async throws -> [MeetingEntity] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let container = RecapDataContainer.shared else { return [] }
        let index = RecapWorkspaceIndex(modelContainer: container)
        return await index.searchMeetings(query: trimmed, excluding: nil, since: nil, limit: 8)
            .map(MeetingEntity.init)
    }
}
