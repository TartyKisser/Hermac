import Foundation
@preconcurrency import EventKit

@MainActor
protocol RemindersClient: AnyObject {
    var hasAccess: Bool { get }
    func requestAccess() async throws
    func availableLists() -> [ReminderList]
    func create(_ draft: ReminderDraft) throws -> String
}

@MainActor
final class RemindersService: RemindersClient {
    private let eventStore = EKEventStore()

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    func requestAccess() async throws {
        if hasAccess { return }
        guard try await eventStore.requestFullAccessToReminders() else {
            throw HermesServiceError(message: "请在系统设置的“隐私与安全性 → 提醒事项”中允许 Hermac，然后重新确认创建。")
        }
    }

    func availableLists() -> [ReminderList] {
        guard hasAccess else { return [] }
        return eventStore.calendars(for: .reminder).filter(\.allowsContentModifications)
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
    }

    func create(_ draft: ReminderDraft) throws -> String {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw HermesServiceError(message: "请填写事项标题。") }
        let calendar = draft.calendarID.flatMap(eventStore.calendar(withIdentifier:))
            ?? (draft.calendarID == nil ? eventStore.defaultCalendarForNewReminders() : nil)
        guard let calendar, calendar.allowsContentModifications else {
            throw HermesServiceError(message: "没有可写入的提醒事项清单，请在提醒事项 App 中创建清单后重新选择。")
        }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = draft.reminderNotes
        reminder.location = draft.location.isEmpty ? nil : draft.location
        reminder.priority = draft.priority
        reminder.dueDateComponents = draft.dueComponents()
        if draft.includesTime, let date = draft.dueDate { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
        try eventStore.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }
}
