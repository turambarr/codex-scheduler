import Foundation

// MARK: - Errors

public enum SchedulerError: Error, Equatable, CustomStringConvertible {
    case invalidTimeZone(String)
    case dependencyCycle([String])
    case invalidInput(String)

    public var description: String {
        switch self {
        case .invalidTimeZone(let id): return "invalid or unknown time zone identifier: \(id)"
        case .dependencyCycle(let ids): return "dependency cycle detected among tasks: \(ids.sorted().joined(separator: ", "))"
        case .invalidInput(let message): return message
        }
    }
}

// MARK: - Intervals

/// A half-open time interval `[start, end)` expressed in absolute instants.
/// Duration is always computed in real elapsed time, never by local clock arithmetic,
/// so intervals that span a DST transition are measured correctly.
public struct Interval: Hashable, Codable, Sendable, Comparable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    public var minutes: Int { Int((duration / 60).rounded()) }
    public var isEmpty: Bool { end <= start }

    /// Intersection with another interval, or nil when they do not overlap.
    public func intersection(_ other: Interval) -> Interval? {
        let s = max(start, other.start)
        let e = min(end, other.end)
        return e > s ? Interval(start: s, end: e) : nil
    }

    /// True when the two intervals share at least one instant.
    public func overlaps(_ other: Interval) -> Bool {
        start < other.end && other.start < end
    }

    public static func < (lhs: Interval, rhs: Interval) -> Bool {
        lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
    }
}

// MARK: - Local calendar value types

public struct LocalDate: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

public struct LocalTime: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    public var description: String {
        String(format: "%02d:%02d", hour, minute)
    }

    public static func < (lhs: LocalTime, rhs: LocalTime) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }
}

// MARK: - Scheduling configuration

public struct DayWindow: Hashable, Codable, Sendable {
    public var start: LocalTime
    public var end: LocalTime

    public init(start: LocalTime, end: LocalTime) {
        self.start = start
        self.end = end
    }
}

public struct WeekdayWindows: Hashable, Codable, Sendable {
    /// `Calendar` weekday numbering: 1 = Sunday … 7 = Saturday.
    public var weekday: Int
    public var windows: [DayWindow]

    public init(weekday: Int, windows: [DayWindow]) {
        self.weekday = weekday
        self.windows = windows
    }
}

/// Tunable scheduling policy. Every value here is an adjustable assumption, not a hard rule.
public struct ScheduleConfig: Hashable, Codable, Sendable {
    public var timeZoneID: String
    /// Working windows per weekday. Weekdays that are absent (or map to an empty list)
    /// are not used for flexible task placement at all.
    public var weeklyWindows: [WeekdayWindows]
    /// Placement granularity in minutes. Allocated blocks are aligned to it.
    public var granularityMinutes: Int
    /// Preferred distance from the deadline, measured in working days (Mon–Fri).
    public var bufferWorkdays: Int
    /// Where inside the feasible window a block ideally lands (0…1).
    public var targetPosition: Double
    /// Longest single work session; longer tasks are split (when splittable).
    public var maxSessionMinutes: Int
    /// Default minimum usable chunk when a task is split.
    public var minChunkMinutes: Int

    public init(
        timeZoneID: String,
        weeklyWindows: [WeekdayWindows],
        granularityMinutes: Int = 15,
        bufferWorkdays: Int = 1,
        targetPosition: Double = 0.45,
        maxSessionMinutes: Int = 90,
        minChunkMinutes: Int = 30
    ) {
        self.timeZoneID = timeZoneID
        self.weeklyWindows = weeklyWindows
        self.granularityMinutes = granularityMinutes
        self.bufferWorkdays = bufferWorkdays
        self.targetPosition = targetPosition
        self.maxSessionMinutes = maxSessionMinutes
        self.minChunkMinutes = minChunkMinutes
    }

    private static func w(_ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int) -> DayWindow {
        DayWindow(start: LocalTime(hour: h1, minute: m1), end: LocalTime(hour: h2, minute: m2))
    }

    /// Weekday working hours with a midday break.
    public static var `default`: ScheduleConfig {
        let windows = [w(9, 0, 12, 0), w(13, 0, 18, 0)]
        return ScheduleConfig(
            timeZoneID: TimeZone.current.identifier,
            weeklyWindows: (2...6).map { WeekdayWindows(weekday: $0, windows: windows) }
        )
    }

    public func windows(forWeekday weekday: Int) -> [DayWindow] {
        weeklyWindows.first(where: { $0.weekday == weekday })?.windows ?? []
    }
}

// MARK: - Calendar items

public enum Availability: String, Codable, Sendable, CaseIterable {
    case busy
    case free
    case tentative
    case unavailable
    case unknown
}

/// A busy-time contribution from an external calendar (or from the local store).
public struct BusyBlock: Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var interval: Interval
    public var availability: Availability
    public var isAllDay: Bool
    public var calendarID: String?
    public var isRecurring: Bool

    public init(
        id: String,
        title: String,
        interval: Interval,
        availability: Availability,
        isAllDay: Bool = false,
        calendarID: String? = nil,
        isRecurring: Bool = false
    ) {
        self.id = id
        self.title = title
        self.interval = interval
        self.availability = availability
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.isRecurring = isRecurring
    }

    /// Whether this block must be treated as occupied time.
    /// Unknown availability is conservatively treated as busy; only `.free` is ignored.
    public var blocksScheduling: Bool { availability != .free }
}

/// A previously committed block that a re-scheduling run must not move.
public struct LockedBlock: Hashable, Codable, Sendable {
    public var taskID: String
    public var interval: Interval

    public init(taskID: String, interval: Interval) {
        self.taskID = taskID
        self.interval = interval
    }
}

// MARK: - Tasks

public enum TaskSource: String, Codable, Sendable, CaseIterable {
    case reminder
    case userRequest = "user_request"
    case plan
    case external
}

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case scheduled
    case done
    case blocked
    case cancelled
}

public enum TaskPreference: String, Codable, Sendable, CaseIterable {
    case morning
    case afternoon
    case any
}

public enum Deadline: Hashable, Codable, Sendable {
    /// Deadline is a calendar date; the task must end by the end of that local day.
    case date(LocalDate)
    /// Deadline is an exact instant.
    case instant(Date)
}

public struct PlanTask: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var source: TaskSource
    public var estimatedMinutes: Int
    public var remainingMinutes: Int
    /// 1 = highest priority … 5 = lowest.
    public var priority: Int
    public var earliestStart: Date?
    public var deadline: Deadline?
    public var splittable: Bool
    public var minChunkMinutes: Int
    public var preference: TaskPreference
    public var status: TaskStatus
    /// Task ids that must finish before this one starts.
    public var dependsOn: [String]
    /// Task ids explicitly allowed to share the same time slot as this task.
    public var allowConcurrentWith: [String]
    public var notes: String?

    public init(
        id: String,
        title: String,
        source: TaskSource = .userRequest,
        estimatedMinutes: Int,
        remainingMinutes: Int? = nil,
        priority: Int = 3,
        earliestStart: Date? = nil,
        deadline: Deadline? = nil,
        splittable: Bool = true,
        minChunkMinutes: Int = 30,
        preference: TaskPreference = .any,
        status: TaskStatus = .pending,
        dependsOn: [String] = [],
        allowConcurrentWith: [String] = [],
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.estimatedMinutes = estimatedMinutes
        self.remainingMinutes = remainingMinutes ?? estimatedMinutes
        self.priority = priority
        self.earliestStart = earliestStart
        self.deadline = deadline
        self.splittable = splittable
        self.minChunkMinutes = minChunkMinutes
        self.preference = preference
        self.status = status
        self.dependsOn = dependsOn
        self.allowConcurrentWith = allowConcurrentWith
        self.notes = notes
    }
}

// MARK: - Plan output

public struct Assignment: Hashable, Codable, Sendable {
    public var taskID: String
    public var interval: Interval
    public var minutes: Int
    public var chunkIndex: Int
    public var splitCount: Int

    public init(taskID: String, interval: Interval, minutes: Int, chunkIndex: Int, splitCount: Int) {
        self.taskID = taskID
        self.interval = interval
        self.minutes = minutes
        self.chunkIndex = chunkIndex
        self.splitCount = splitCount
    }
}

public enum UnscheduledReason: String, Codable, Sendable {
    case deadlinePassed = "deadline_passed"
    case noFreeInterval = "no_free_interval"
    case insufficientTotalTime = "insufficient_total_time"
    case minChunkUnmet = "min_chunk_unmet"
    case noContiguousBlock = "no_contiguous_block"
    case dependencyUnscheduled = "dependency_unscheduled"
    case dependencyCycle = "dependency_cycle"
}

public struct UnscheduledTask: Hashable, Codable, Sendable {
    public var taskID: String
    public var title: String
    public var reason: UnscheduledReason
    public var detail: String
    public var shortfallMinutes: Int

    public init(taskID: String, title: String, reason: UnscheduledReason, detail: String, shortfallMinutes: Int) {
        self.taskID = taskID
        self.title = title
        self.reason = reason
        self.detail = detail
        self.shortfallMinutes = shortfallMinutes
    }
}

public struct ScheduleStatistics: Hashable, Codable, Sendable {
    public var totalWindowMinutes: Int
    public var busyMinutes: Int
    public var freeMinutes: Int
    public var allocatedMinutes: Int
    public var utilization: Double
    public var taskCount: Int
    public var scheduledTaskCount: Int

    public init(
        totalWindowMinutes: Int,
        busyMinutes: Int,
        freeMinutes: Int,
        allocatedMinutes: Int,
        utilization: Double,
        taskCount: Int,
        scheduledTaskCount: Int
    ) {
        self.totalWindowMinutes = totalWindowMinutes
        self.busyMinutes = busyMinutes
        self.freeMinutes = freeMinutes
        self.allocatedMinutes = allocatedMinutes
        self.utilization = utilization
        self.taskCount = taskCount
        self.scheduledTaskCount = scheduledTaskCount
    }
}

/// The single authoritative artifact that later phases preview and confirm.
public struct SchedulePlan: Hashable, Codable, Sendable {
    public var planID: String
    public var generatedAt: Date
    public var rangeStart: Date
    public var rangeEnd: Date
    public var timeZoneID: String
    public var assignments: [Assignment]
    public var unscheduled: [UnscheduledTask]
    public var freeIntervals: [Interval]
    public var statistics: ScheduleStatistics
    public var assumptions: [String]
    public var warnings: [String]

    public init(
        planID: String,
        generatedAt: Date,
        rangeStart: Date,
        rangeEnd: Date,
        timeZoneID: String,
        assignments: [Assignment],
        unscheduled: [UnscheduledTask],
        freeIntervals: [Interval],
        statistics: ScheduleStatistics,
        assumptions: [String],
        warnings: [String]
    ) {
        self.planID = planID
        self.generatedAt = generatedAt
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.timeZoneID = timeZoneID
        self.assignments = assignments
        self.unscheduled = unscheduled
        self.freeIntervals = freeIntervals
        self.statistics = statistics
        self.assumptions = assumptions
        self.warnings = warnings
    }
}
