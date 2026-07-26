import EventKit
import Foundation
import RecapModels

public enum ReminderDispatchError: LocalizedError {
    case accessDenied
    case saveFailed(String)
    case listUnavailable

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "未获得提醒事项权限"
        case .saveFailed(let msg):
            return "保存提醒失败：\(msg)"
        case .listUnavailable:
            return "无法创建「会议待办」列表"
        }
    }
}

/// EventKit 待办分发（原生优先）。成功前禁止把 ActionItem 标为 dispatched。
@MainActor
public final class ReminderDispatcher {
    public static let shared = ReminderDispatcher()

    private let store = EKEventStore()
    private let listTitle = "会议待办"

    public init() {}

    public func ensureAccess() async throws {
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw ReminderDispatchError.accessDenied }
    }

    public func dispatch(_ item: ActionItem, meetingTitle: String) async throws -> String {
        try await ensureAccess()

        if let existingId = item.externalReminderId, !existingId.isEmpty {
            let predicate = store.predicateForReminders(in: nil)
            let ids = try await fetchReminderIdentifiers(matching: predicate)
            if ids.contains(existingId) {
                return existingId
            }
        }

        let calendar = try reminderList()
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = item.task
        reminder.notes = ReminderDispatchNotes.make(
            meetingTitle: meetingTitle,
            evidenceQuote: item.evidenceQuote
        )
        reminder.priority = ReminderDispatchNotes.ekPriority(from: item.priority)

        if let due = item.due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ReminderDispatchError.saveFailed(error.localizedDescription)
        }

        let id = reminder.calendarItemIdentifier
        guard !id.isEmpty else {
            throw ReminderDispatchError.saveFailed("未获得 reminder id")
        }
        return id
    }

    private func reminderList() throws -> EKCalendar {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == listTitle }) {
            return existing
        }
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .local })
                ?? store.sources.first else {
            throw ReminderDispatchError.listUnavailable
        }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = listTitle
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        return cal
    }

    /// 只回传 Sendable 的 identifier，避免把非 Sendable 的 `EKReminder` 送出回调队列。
    private func fetchReminderIdentifiers(matching predicate: NSPredicate) async throws -> Set<String> {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Set<String>, Error>) in
            store.fetchReminders(matching: predicate) { reminders in
                let ids = Set((reminders ?? []).compactMap { reminder -> String? in
                    let id = reminder.calendarItemIdentifier
                    return id.isEmpty ? nil : id
                })
                cont.resume(returning: ids)
            }
        }
    }
}
