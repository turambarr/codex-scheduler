import Foundation

/// The complete set of calendar capabilities the scheduler is allowed to use.
///
/// This protocol is deliberately read-only: there is no `save`, `remove` or `commit`
/// member, so no code path can write to Apple Calendar or Reminders by accident.
/// Phase 1 ships exactly this surface.
public protocol CalendarSource: Sendable {
    func eventCalendars() throws -> [CalendarSummary]
    func reminderCalendars() throws -> [CalendarSummary]
    func events(from start: Date, to end: Date, calendarIDs: [String]?) throws -> [EventItem]
    func reminders(
        includeCompleted: Bool,
        dueFrom: Date?,
        dueTo: Date?,
        listIDs: [String]?
    ) async throws -> [ReminderItem]
}

extension EventKitBridge: CalendarSource {}
