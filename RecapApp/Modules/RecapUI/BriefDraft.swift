import Foundation
import RecapModels

/// 开录前尚未入库的底稿草稿（避免 @State 持有未 insert 的 @Model）。
@Observable
final class BriefDraft {
    var sources: [BriefSource] = []
    var agenda: [AgendaItem] = []
    var openItems: [OpenItem] = []
    var entityHints: [String] = []
    var suggestedTitle: String?

    var isEmpty: Bool {
        agenda.isEmpty && openItems.isEmpty && sources.isEmpty
    }

    var chipLabel: String {
        if isEmpty { return "底稿·未添加" }
        var parts: [String] = []
        if !agenda.isEmpty { parts.append("议程\(agenda.count)项") }
        if !openItems.isEmpty { parts.append("遗留\(openItems.count)") }
        if parts.isEmpty { parts.append("已添加") }
        return "底稿·\(parts.joined(separator: "·"))"
    }

    var summaryForPrompt: String {
        BriefPromptBuilder.build(agenda: agenda, openItems: openItems, entityHints: entityHints)
    }

    func merge(parse: BriefParseResult, source: BriefSource) {
        sources.append(source)

        if agenda.isEmpty {
            agenda = parse.agenda
        } else if !parse.agenda.isEmpty {
            let existingTitles = Set(agenda.map { $0.title.lowercased() })
            var order = (agenda.map(\.order).max() ?? 0) + 1
            for item in parse.agenda where !existingTitles.contains(item.title.lowercased()) {
                var copy = item
                copy.order = order
                order += 1
                agenda.append(copy)
            }
        }

        if !parse.openItems.isEmpty {
            let existing = Set(openItems.map { $0.text.lowercased() })
            for item in parse.openItems where !existing.contains(item.text.lowercased()) {
                openItems.append(item)
            }
        }

        for h in parse.entityHints where !entityHints.contains(h) {
            entityHints.append(h)
        }
        entityHints = Array(entityHints.prefix(40))

        if let title = parse.suggestedTitle, suggestedTitle == nil || suggestedTitle?.isEmpty == true {
            suggestedTitle = title
        }
    }

    func clear() {
        sources = []
        agenda = []
        openItems = []
        entityHints = []
        suggestedTitle = nil
    }

    /// 物化为 SwiftData 实体（调用方 insert）。
    func makeModel(attachedTo meeting: Meeting) -> MeetingBrief {
        let brief = MeetingBrief(
            sources: sources,
            agenda: agenda,
            openItems: openItems,
            entityHints: entityHints,
            summaryForPrompt: summaryForPrompt,
            suggestedTitle: suggestedTitle,
            meeting: meeting
        )
        return brief
    }
}
