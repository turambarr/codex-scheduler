import Foundation

public struct ManagedItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case event, reminder }

    public let id: String
    public let taskID: String
    public let kind: Kind
    public var title: String
    public var start: Date
    public var end: Date?
    public var completed: Bool
    public var earliestAllowed: Date?
    public var latestAllowed: Date?

    public init(id: String, taskID: String, kind: Kind, title: String,
                start: Date, end: Date? = nil, completed: Bool = false,
                earliestAllowed: Date? = nil, latestAllowed: Date? = nil) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.title = title
        self.start = start
        self.end = end
        self.completed = completed
        self.earliestAllowed = earliestAllowed
        self.latestAllowed = latestAllowed
    }

    public var marker: String { "[CodexScheduler:\(id)]" }
}

public struct ScheduleChange: Codable, Equatable, Sendable {
    public let before: ManagedItem?
    public let after: ManagedItem?

    public init(before: ManagedItem? = nil, after: ManagedItem? = nil) {
        self.before = before
        self.after = after
    }

    public var item: ManagedItem { (after ?? before)! }
    public var action: String { before == nil ? "create" : after == nil ? "remove" : "update" }
}

public struct ManagedDraft: Codable, Equatable, Sendable {
    public let id: String
    public let timeZoneID: String
    public let created: Date
    public let changes: [ScheduleChange]
    public let concurrentPairs: [[String]]
    public let taskCompletion: TaskCompletionChange?

    public init(id: String = UUID().uuidString, timeZoneID: String, created: Date,
                changes: [ScheduleChange], concurrentPairs: [[String]] = [], taskCompletion: TaskCompletionChange? = nil) {
        self.id = id
        self.timeZoneID = timeZoneID
        self.created = created
        self.changes = changes
        self.concurrentPairs = concurrentPairs
        self.taskCompletion = taskCompletion
    }

    public var expires: Date { created.addingTimeInterval(1_800) }
}

public struct TaskCompletionChange: Codable, Equatable, Sendable {
    public let taskID: String
    public let before: Bool
    public let after: Bool

    public init(taskID: String, before: Bool, after: Bool) {
        self.taskID = taskID
        self.before = before
        self.after = after
    }
}

public struct ManagedJournal: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case preview, awaitingConfirmation = "awaiting_confirmation", declined, applying, applied, needsReview = "needs_review"
    }

    public let draft: ManagedDraft
    public var state: State = .preview
    public var completedOperations = 0
    public var inFlight: Int?
    public var message: String?

    public init(draft: ManagedDraft) { self.draft = draft }
}

public struct ManagedContainer: Codable, Equatable, Sendable {
    public let calendarID: String
    public let sourceID: String

    public init(calendarID: String, sourceID: String) {
        self.calendarID = calendarID
        self.sourceID = sourceID
    }
}
