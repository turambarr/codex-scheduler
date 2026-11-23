import EventKit
import Foundation
import SchedulerCore

// MARK: - Transfer types

public struct CalendarSummary: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var source: String
    public var kind: String
    public var allowsContentModifications: Bool
    public var isImmutable: Bool

    public init(
        id: String,
        title: String,
        source: String,
        kind: String,
        allowsContentModifications: Bool,
        isImmutable: Bool
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.kind = kind
        self.allowsContentModifications = allowsContentModifications
        self.isImmutable = isImmutable
    }
}

public struct EventItem: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var availability: Availability
    public var calendarID: String
    public var calendarTitle: String
    public var isRecurring: Bool
    public var hasAttendees: Bool
    public var notes: String?
    public var originalOccurrence: Date?
    public var sourceTimeZoneID: String?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        availability: Availability = .busy,
        calendarID: String = "cal",
        calendarTitle: String = "Calendar",
        isRecurring: Bool = false,
        hasAttendees: Bool = false,
        notes: String? = nil,
        originalOccurrence: Date? = nil,
        sourceTimeZoneID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.availability = availability
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.isRecurring = isRecurring
        self.hasAttendees = hasAttendees
        self.notes = notes
        self.originalOccurrence = originalOccurrence
        self.sourceTimeZoneID = sourceTimeZoneID
    }

    /// Convert to the scheduling engine's busy-block representation.
    public var busyBlock: BusyBlock {
        BusyBlock(
            id: id,
            title: title,
            interval: Interval(start: start, end: end),
            availability: availability,
            isAllDay: isAllDay,
            calendarID: calendarID,
            isRecurring: isRecurring
        )
    }
}

public struct ReminderItem: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var notes: String?
    public var listID: String
    public var listTitle: String
    public var dueDate: Date?
    public var hasDueTime: Bool
    public var isCompleted: Bool
    public var completionDate: Date?
    /// EventKit priority: 0 = none, 1 = highest … 9 = lowest.
    public var priority: Int
    public var localDueDate: String?
    public var isRecurring: Bool
    public var recurrenceFrequencies: [String]
    public var hasAlarms: Bool
    public var absoluteAlarms: [Date]

    public init(
        id: String,
        title: String,
        notes: String? = nil,
        listID: String = "list",
        listTitle: String = "Reminders",
        dueDate: Date? = nil,
        hasDueTime: Bool = false,
        isCompleted: Bool = false,
        completionDate: Date? = nil,
        priority: Int = 0,
        localDueDate: String? = nil,
        isRecurring: Bool = false,
        recurrenceFrequencies: [String] = [],
        hasAlarms: Bool = false,
        absoluteAlarms: [Date] = []
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.listID = listID
        self.listTitle = listTitle
        self.dueDate = dueDate
        self.hasDueTime = hasDueTime
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.priority = priority
        self.localDueDate = localDueDate
        self.isRecurring = isRecurring
        self.recurrenceFrequencies = recurrenceFrequencies
        self.hasAlarms = hasAlarms
        self.absoluteAlarms = absoluteAlarms
    }

    /// Map EventKit priority onto the scheduler's 1…5 priority scale.
    public var schedulerPriority: Int {
        switch priority {
        case 1...3: return 1
        case 4...5: return 2
        case 6: return 3
        case 7...8: return 4
        case 9: return 5
        default: return 3
        }
    }
}

public struct EventKitError: Error, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Bridge

/// Thin, strictly read-only adapter over EventKit.
///
/// The bridge never calls `save`, `remove` or `commit`. Phase 1 of the project is
/// deliberately a read-only integration; write paths arrive in a later phase behind
/// an explicit confirmation step.
public final class EventKitBridge: @unchecked Sendable {
    private let store: EKEventStore
    private let calendar: Calendar

    public init(timeZoneIdentifier: String = TimeZone.current.identifier) throws {
        self.store = EKEventStore()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        cal.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = cal
    }

    // MARK: Permissions

    public static func permissionReport() -> PermissionReport {
        PermissionReport(
            calendar: PermissionMapper.state(from: EKEventStore.authorizationStatus(for: .event)),
            reminders: PermissionMapper.state(from: EKEventStore.authorizationStatus(for: .reminder))
        )
    }

    /// Triggers the system consent prompts. Must be called from a GUI-session process
    /// that has `NSCalendarsFullAccessUsageDescription` / `NSRemindersFullAccessUsageDescription`
    /// in its Info.plist (see `scripts/build-app.sh`).
    public func requestAccess() async -> PermissionReport {
        await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { _, _ in
                self.store.requestFullAccessToReminders { _, _ in
                    continuation.resume(returning: EventKitBridge.permissionReport())
                }
            }
        }
    }

    // MARK: Calendars

    public func calendars(for entity: EKEntityType) -> [CalendarSummary] {
        store.calendars(for: entity)
            .map {
                CalendarSummary(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    source: $0.source.title,
                    kind: Self.kindName($0.type),
                    allowsContentModifications: $0.allowsContentModifications,
                    isImmutable: $0.isImmutable
                )
            }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    public func eventCalendars() throws -> [CalendarSummary] {
        try requireAccess(for: .event)
        return calendars(for: .event)
    }

    public func reminderCalendars() throws -> [CalendarSummary] {
        try requireAccess(for: .reminder)
        return calendars(for: .reminder)
    }

    private func requireAccess(for entity: EKEntityType) throws {
        let state = PermissionMapper.state(from: EKEventStore.authorizationStatus(for: entity))
        guard state == .authorized || state == .fullAccess else {
            let name = entity == .event ? "calendar" : "reminders"
            throw EventKitError("\(name) access is not granted (state: \(state.rawValue))")
        }
    }

    private func selectedCalendars(_ ids: [String]?, for entity: EKEntityType) throws -> [EKCalendar]? {
        guard let ids else { return nil }
        guard !ids.isEmpty else { throw EventKitError("calendar selection must not be empty") }
        let requested = Set(ids)
        let selected = store.calendars(for: entity).filter { requested.contains($0.calendarIdentifier) }
        guard selected.count == requested.count else {
            throw EventKitError("one or more selected calendars or reminder lists are no longer available")
        }
        return selected
    }

    private static func kindName(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "caldav"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }

    // MARK: Events

    public func events(from start: Date, to end: Date, calendarIDs: [String]? = nil) throws -> [EventItem] {
        try requireAccess(for: .event)
        let selected = try selectedCalendars(calendarIDs, for: .event)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        let raw = store.events(matching: predicate)
        return raw
            .filter { event in
                event.status != .canceled && !(event.attendees ?? []).contains {
                    $0.isCurrentUser && $0.participantStatus == .declined
                }
            }
            .map { event in
                let recurring = event.hasRecurrenceRules || event.isDetached
                let occurrence = recurring ? (event.occurrenceDate ?? event.startDate) : nil
                let baseID = event.eventIdentifier ?? event.calendarItemIdentifier
                let id = occurrence.map {
                    "\(event.calendar.calendarIdentifier):\(baseID):\($0.timeIntervalSince1970)"
                } ?? baseID
                return EventItem(
                    id: id,
                    title: event.title ?? "(untitled)",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    availability: Self.availability(event.availability),
                    calendarID: event.calendar.calendarIdentifier,
                    calendarTitle: event.calendar.title,
                    isRecurring: recurring,
                    hasAttendees: !(event.attendees ?? []).isEmpty,
                    notes: event.notes,
                    originalOccurrence: occurrence,
                    sourceTimeZoneID: event.timeZone?.identifier
                )
            }
            .sorted { ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id) }
    }

    private static func availability(_ value: EKEventAvailability) -> Availability {
        switch value {
        case .busy: return .busy
        case .free: return .free
        case .tentative: return .tentative
        case .unavailable: return .unavailable
        default: return .unknown
        }
    }

    // MARK: Reminders

    /// Fetches reminders. `includeCompleted` false returns open items only.
    public func reminders(
        includeCompleted: Bool = false,
        dueFrom: Date? = nil,
        dueTo: Date? = nil,
        listIDs: [String]? = nil
    ) async throws -> [ReminderItem] {
        try requireAccess(for: .reminder)
        let selected = try selectedCalendars(listIDs, for: .reminder)

        let predicate = store.predicateForReminders(in: selected)
        let raw: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: EventKitError("EventKit did not return a reminder result"))
                    return
                }
                continuation.resume(returning: reminders)
            }
        }

        let items: [ReminderItem] = raw.map { reminder in
            let components = reminder.dueDateComponents
            let due = components.flatMap { calendar.date(from: $0) }
            let hasTime = components?.hour != nil || components?.minute != nil
            let localDueDate: String?
            if !hasTime, let year = components?.year, let month = components?.month, let day = components?.day {
                localDueDate = LocalDate(year: year, month: month, day: day).description
            } else {
                localDueDate = nil
            }
            return ReminderItem(
                id: reminder.calendarItemIdentifier,
                title: reminder.title ?? "(untitled)",
                notes: reminder.notes,
                listID: reminder.calendar.calendarIdentifier,
                listTitle: reminder.calendar.title,
                dueDate: due,
                hasDueTime: hasTime,
                isCompleted: reminder.isCompleted,
                completionDate: reminder.completionDate,
                priority: reminder.priority,
                localDueDate: localDueDate,
                isRecurring: reminder.hasRecurrenceRules,
                recurrenceFrequencies: (reminder.recurrenceRules ?? []).map { String(describing: $0.frequency) },
                hasAlarms: reminder.hasAlarms,
                absoluteAlarms: (reminder.alarms ?? []).compactMap(\.absoluteDate).sorted()
            )
        }

        return items
            .filter { includeCompleted || !$0.isCompleted }
            .filter { item in
                guard let due = item.dueDate else { return true }
                if let dueFrom, due < dueFrom { return false }
                if let dueTo, due >= dueTo { return false }
                return true
            }
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (l?, r?): return (l, lhs.title, lhs.id) < (r, rhs.title, rhs.id)
                case (nil, _?): return false
                case (_?, nil): return true
                default: return (lhs.title, lhs.id) < (rhs.title, rhs.id)
                }
            }
    }
}
