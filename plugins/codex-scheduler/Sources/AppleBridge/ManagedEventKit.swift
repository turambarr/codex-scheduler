import EventKit
import Foundation
import SchedulerCore

public protocol ManagedAppleStore: Sendable {
    func container(_ kind: ManagedItem.Kind, named name: String, bound: ManagedContainer?,
                   create: Bool) async throws -> ManagedContainer?
    func current(_ change: ScheduleChange, in container: ManagedContainer) async throws -> ManagedItem?
    func apply(_ change: ScheduleChange, in container: ManagedContainer) async throws
}

public actor ManagedEventKit: ManagedAppleStore {
    private let store = EKEventStore()
    private let timeZone: TimeZone

    public init(timeZoneID: String) throws {
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            throw SchedulerError.invalidTimeZone(timeZoneID)
        }
        self.timeZone = timeZone
    }

    public func container(_ kind: ManagedItem.Kind, named name: String, bound: ManagedContainer?,
                          create: Bool) throws -> ManagedContainer? {
        let type = try entity(kind)
        if let bound {
            let calendar = try resolve(bound, kind: kind)
            guard calendar.title == name else { throw EventKitError("专用日历或清单名称已变化，请先核对") }
            return bound
        }
        guard !store.calendars(for: type).contains(where: { $0.title == name }) else {
            throw EventKitError("已有同名日历或清单，未绑定其身份，已暂停写入")
        }
        let defaultCalendar = type == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        guard let source = defaultCalendar?.source else { throw EventKitError("没有可用的默认日历或提醒账户") }
        guard create else { return nil }
        let calendar = EKCalendar(for: type, eventStore: store)
        calendar.source = source
        calendar.title = name
        try store.saveCalendar(calendar, commit: true)
        return ManagedContainer(calendarID: calendar.calendarIdentifier, sourceID: source.sourceIdentifier)
    }

    public func current(_ change: ScheduleChange, in container: ManagedContainer) async throws -> ManagedItem? {
        let calendar = try resolve(container, kind: change.item.kind)
        guard let item = try await lookup(change, in: calendar) else { return nil }
        return try snapshot(item, template: change.item)
    }

    public func apply(_ change: ScheduleChange, in container: ManagedContainer) async throws {
        let calendar = try resolve(container, kind: change.item.kind)
        let existing = try await lookup(change, in: calendar)
        let actual = try existing.map { try snapshot($0, template: change.item) }
        guard actual == change.before else { throw EventKitError("事项已变化，需重新预览") }
        switch (change.item.kind, change.after) {
        case (.event, let after?):
            let event = (existing as? EKEvent) ?? EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = after.title
            event.notes = after.marker
            event.timeZone = timeZone
            event.startDate = after.start
            event.endDate = after.end
            try store.save(event, span: .thisEvent, commit: true)
        case (.event, nil):
            guard let event = existing as? EKEvent else { throw EventKitError("未找到待移除的自管事件") }
            try store.remove(event, span: .thisEvent, commit: true)
        case (.reminder, let after?):
            let item = (existing as? EKReminder) ?? EKReminder(eventStore: store)
            item.calendar = calendar
            item.title = after.title
            item.notes = after.marker
            var calendarMath = Calendar(identifier: .gregorian)
            calendarMath.timeZone = timeZone
            item.dueDateComponents = calendarMath.dateComponents(in: timeZone, from: after.start)
            item.alarms = [EKAlarm(absoluteDate: after.start)]
            item.isCompleted = after.completed
            try store.save(item, commit: true)
        case (.reminder, nil):
            guard let reminder = existing as? EKReminder else { throw EventKitError("未找到待移除的自管提醒") }
            try store.remove(reminder, commit: true)
        }
    }

    private func entity(_ kind: ManagedItem.Kind) throws -> EKEntityType {
        let report = EventKitBridge.permissionReport()
        let canAccess = kind == .event ? report.canReadCalendar : report.canReadReminders
        guard canAccess else {
            throw EventKitError(kind == .event ? "需要 macOS 日历完整访问权限" : "需要 macOS 提醒事项完整访问权限")
        }
        return kind == .event ? .event : .reminder
    }

    private func resolve(_ bound: ManagedContainer, kind: ManagedItem.Kind) throws -> EKCalendar {
        let type = try entity(kind)
        guard let value = store.calendars(for: type).first(where: { $0.calendarIdentifier == bound.calendarID }),
              value.source.sourceIdentifier == bound.sourceID, value.allowsContentModifications else {
            throw EventKitError("已绑定的日历或提醒清单无法验证，已暂停写入")
        }
        return value
    }

    private func lookup(_ change: ScheduleChange, in calendar: EKCalendar) async throws -> EKCalendarItem? {
        let matches: [EKCalendarItem]
        if change.item.kind == .event {
            let dates = Set([change.before?.start, change.after?.start].compactMap { $0 })
            var unique: [String: EKEvent] = [:]
            for date in dates {
                let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-86_400),
                                                         end: date.addingTimeInterval(86_400), calendars: [calendar])
                for event in store.events(matching: predicate) where event.notes?.contains(change.item.marker) == true {
                    unique[event.calendarItemIdentifier] = event
                }
            }
            matches = Array(unique.values)
        } else {
            let predicate = store.predicateForReminders(in: [calendar])
            let reminders: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
                store.fetchReminders(matching: predicate) { result in
                    if let result { continuation.resume(returning: result) }
                    else { continuation.resume(throwing: EventKitError("未能读取专用提醒清单")) }
                }
            }
            matches = reminders.filter { $0.notes?.contains(change.item.marker) == true }
        }
        guard matches.count <= 1 else { throw EventKitError("同一管理标识匹配多个事项，已暂停写入") }
        return matches.first
    }

    private func snapshot(_ live: EKCalendarItem, template: ManagedItem) throws -> ManagedItem {
        guard live.notes == template.marker, !live.hasRecurrenceRules else {
            throw EventKitError("事项的管理标记、备注或重复规则已变化")
        }
        var item = template
        item.title = live.title
        if let event = live as? EKEvent, !event.isAllDay, !event.isDetached,
           !(event.hasAttendees || event.hasAlarms), (event.location ?? "").isEmpty,
           event.availability != .free, event.url == nil {
            item.start = event.startDate
            item.end = event.endDate
        } else if let reminder = live as? EKReminder,
                  let due = reminder.dueDateComponents?.date, reminder.url == nil,
                  reminder.alarms?.count == 1, reminder.alarms?.first?.absoluteDate == due {
            item.start = due
            item.completed = reminder.isCompleted
        } else {
            throw EventKitError("自管事项的类型或设置已变化，需人工核对")
        }
        return item
    }
}
