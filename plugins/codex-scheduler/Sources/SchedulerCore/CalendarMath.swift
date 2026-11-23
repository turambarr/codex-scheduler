import Foundation

/// All calendar arithmetic funnels through this type so that time-zone and DST
/// behaviour is identical in tests, in the CLI and in the MCP server.
public struct CalendarMath: Sendable {
    public let timeZone: TimeZone
    public let calendar: Calendar

    public init(timeZoneIdentifier: String) throws {
        guard let tz = TimeZone(identifier: timeZoneIdentifier) else {
            throw SchedulerError.invalidTimeZone(timeZoneIdentifier)
        }
        self.timeZone = tz
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.firstWeekday = 2
        self.calendar = cal
    }

    public var identifier: String { timeZone.identifier }

    // MARK: Day boundaries

    public func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    public func startOfNextDay(_ date: Date) -> Date {
        let start = startOfDay(date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    /// Local start-of-day dates covering `[start, end)`.
    public func days(from start: Date, to end: Date) -> [Date] {
        var result: [Date] = []
        var day = startOfDay(start)
        var guardCount = 0
        while day < end && guardCount < 4_000 {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            guardCount += 1
        }
        return result
    }

    public func weekday(of date: Date) -> Int {
        calendar.component(.weekday, from: date)
    }

    public func localDate(of date: Date) -> LocalDate {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return LocalDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    public func localTime(of date: Date) -> LocalTime {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return LocalTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    /// The instant for a local wall-clock time on a given day.
    /// Returns nil when that wall-clock time does not exist (DST spring-forward gap).
    /// For times that occur twice (fall-back), the earlier (pre-transition) instant is used.
    public func date(onDay day: Date, at time: LocalTime) -> Date? {
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = time.hour
        comps.minute = time.minute
        comps.second = 0
        guard let candidate = calendar.date(from: comps) else { return nil }
        let check = calendar.dateComponents([.hour, .minute], from: candidate)
        guard check.hour == time.hour, check.minute == time.minute else { return nil }
        return candidate
    }

    public func date(forLocalDate local: LocalDate, time: LocalTime = LocalTime(hour: 0, minute: 0)) -> Date? {
        var comps = DateComponents()
        comps.year = local.year
        comps.month = local.month
        comps.day = local.day
        comps.hour = time.hour
        comps.minute = time.minute
        comps.second = 0
        guard let candidate = calendar.date(from: comps) else { return nil }
        guard localDate(of: candidate) == local, localTime(of: candidate) == time else { return nil }
        return candidate
    }

    /// End of the local day that contains `date` (i.e. the start of the next day).
    public func endOfDay(_ date: Date) -> Date {
        startOfNextDay(date)
    }

    public func endOfDay(for local: LocalDate) -> Date? {
        guard let start = date(forLocalDate: local) else { return nil }
        return startOfNextDay(start)
    }

    // MARK: Deadline handling

    /// Latest permitted instant for a task with the given deadline.
    public func deadlineInstant(_ deadline: Deadline) -> Date? {
        switch deadline {
        case .instant(let date):
            return date
        case .date(let local):
            return endOfDay(for: local)
        }
    }

    /// Moves backwards across configured workdays, preserving wall-clock time.
    public func subtractingWorkdays(_ count: Int, from date: Date, config: ScheduleConfig) -> Date {
        guard count > 0 else { return date }
        var cursor = date
        var remaining = count
        var guardCount = 0
        while remaining > 0 && guardCount < 400 {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
            if !config.windows(forWeekday: weekday(of: cursor)).isEmpty { remaining -= 1 }
            guardCount += 1
        }
        return cursor
    }

    // MARK: Window expansion

    /// Expands the configured weekly windows into concrete intervals clipped to `range`.
    public func workWindows(in range: Interval, config: ScheduleConfig) -> [Interval] {
        var intervals: [Interval] = []
        for day in days(from: range.start, to: range.end) {
            let weekday = self.weekday(of: day)
            for window in config.windows(forWeekday: weekday) {
                guard window.start < window.end else { continue }
                guard let start = date(onDay: day, at: window.start) else {
                    // Window start falls in a DST gap for this date; skip it explicitly.
                    continue
                }
                let end: Date
                if let exact = date(onDay: day, at: window.end) {
                    end = exact
                } else {
                    // Window end falls inside the DST gap: clamp to the transition instant.
                    end = start
                }
                let interval = Interval(start: start, end: end)
                if let clipped = interval.intersection(range), !clipped.isEmpty {
                    intervals.append(clipped)
                }
            }
        }
        return IntervalOps.merge(intervals)
    }

    // MARK: Formatting helpers

    public func formatInstant(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter.string(from: date)
    }

    public func formatDayTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    public func formatDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
