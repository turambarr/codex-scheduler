import Foundation

/// Set-like operations over collections of half-open intervals.
/// Every operation returns intervals that are sorted, disjoint and non-touching.
public enum IntervalOps {

    /// Sorts and coalesces overlapping and directly adjacent intervals.
    public static func merge(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals.filter { !$0.isEmpty }.sorted()
        guard !sorted.isEmpty else { return [] }
        var result: [Interval] = []
        result.reserveCapacity(sorted.count)
        for interval in sorted {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = Interval(start: last.start, end: max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// Removes every instant covered by `cuts` from `base`.
    public static func subtract(_ base: [Interval], _ cuts: [Interval]) -> [Interval] {
        let bases = merge(base)
        let removals = merge(cuts)
        guard !removals.isEmpty else { return bases }
        var result: [Interval] = []
        for interval in bases {
            var pieces = [interval]
            for cut in removals {
                guard cut.overlaps(interval) else { continue }
                var next: [Interval] = []
                for piece in pieces {
                    guard let overlap = piece.intersection(cut) else {
                        next.append(piece)
                        continue
                    }
                    if piece.start < overlap.start {
                        next.append(Interval(start: piece.start, end: overlap.start))
                    }
                    if overlap.end < piece.end {
                        next.append(Interval(start: overlap.end, end: piece.end))
                    }
                }
                pieces = next
            }
            result.append(contentsOf: pieces)
        }
        return merge(result)
    }

    /// Intersection of two interval sets.
    public static func intersection(_ lhs: [Interval], _ rhs: [Interval]) -> [Interval] {
        let a = merge(lhs)
        let b = merge(rhs)
        var result: [Interval] = []
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            if let overlap = a[i].intersection(b[j]) {
                result.append(overlap)
            }
            if a[i].end < b[j].end {
                i += 1
            } else {
                j += 1
            }
        }
        return merge(result)
    }

    /// Clips every interval to `range` and drops empty results.
    public static func clamp(_ intervals: [Interval], to range: Interval) -> [Interval] {
        merge(intervals.compactMap { $0.intersection(range) })
    }

    /// Total covered duration in whole minutes.
    public static func totalMinutes(_ intervals: [Interval]) -> Int {
        merge(intervals).reduce(0) { $0 + $1.minutes }
    }

    /// Intervals whose duration is at least `minimumMinutes`.
    public static func filtering(_ intervals: [Interval], minimumMinutes: Int) -> [Interval] {
        merge(intervals).filter { $0.minutes >= minimumMinutes }
    }

    /// Drops the last `minutes` of an interval, or returns nil when it becomes empty.
    public static func trimmingEnd(_ interval: Interval, byMinutes minutes: Int) -> Interval? {
        guard minutes > 0 else { return interval }
        let end = interval.end.addingTimeInterval(-Double(minutes) * 60)
        return end > interval.start ? Interval(start: interval.start, end: end) : nil
    }
}

/// Rounds instants to a placement grid anchored at local midnight, so that DST days
/// (23h / 25h long) still produce locally-aligned, non-overlapping blocks.
public struct GridAligner: Sendable {
    public let math: CalendarMath
    public let minutes: Int

    public init(math: CalendarMath, minutes: Int) {
        self.math = math
        self.minutes = max(1, minutes)
    }

    /// Rounds `date` up to the next grid point on its own local day.
    public func ceiling(_ date: Date) -> Date {
        let dayStart = math.startOfDay(date)
        let elapsed = date.timeIntervalSince(dayStart)
        let step = Double(minutes) * 60
        let steps = (elapsed / step).rounded(.up)
        let candidate = dayStart.addingTimeInterval(steps * step)
        // Guard against rounding past the next local day on 25-hour days.
        if candidate >= math.startOfNextDay(date) { return date }
        return candidate
    }

    /// Rounds `date` down to the previous grid point on its own local day.
    public func floor(_ date: Date) -> Date {
        let dayStart = math.startOfDay(date)
        let elapsed = max(0, date.timeIntervalSince(dayStart))
        let step = Double(minutes) * 60
        let steps = (elapsed / step).rounded(.down)
        return dayStart.addingTimeInterval(steps * step)
    }

    /// The largest aligned duration not exceeding `minutes`.
    public func alignedMinutes(_ minutesValue: Int) -> Int {
        max(0, (minutesValue / minutes) * minutes)
    }
}
