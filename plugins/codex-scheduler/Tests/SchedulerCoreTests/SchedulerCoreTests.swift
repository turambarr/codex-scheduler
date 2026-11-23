import Foundation
import Testing
@testable import SchedulerCore

// The CommandLineTools toolchain on this machine ships Swift Testing but no XCTest,
// so the suite is written against `Testing`.

@Suite("SchedulerCore")
struct SchedulerCoreTests {

    // MARK: - Helpers

    private func math(_ id: String = "Asia/Shanghai") throws -> CalendarMath {
        try CalendarMath(timeZoneIdentifier: id)
    }

    private func instant(_ m: CalendarMath, _ date: String, _ time: String) throws -> Date {
        let dayParts = date.split(separator: "-").map { Int($0)! }
        let timeParts = time.split(separator: ":").map { Int($0)! }
        return try #require(
            m.date(
                forLocalDate: LocalDate(year: dayParts[0], month: dayParts[1], day: dayParts[2]),
                time: LocalTime(hour: timeParts[0], minute: timeParts[1])
            )
        )
    }

    private func dayRange(_ m: CalendarMath, _ date: String) throws -> Interval {
        let start = try instant(m, date, "00:00")
        return Interval(start: start, end: m.startOfNextDay(start))
    }

    private func busy(
        _ m: CalendarMath,
        _ date: String,
        _ from: String,
        _ to: String,
        availability: Availability = .busy
    ) throws -> BusyBlock {
        BusyBlock(
            id: "\(date)-\(from)-\(to)",
            title: "block",
            interval: Interval(start: try instant(m, date, from), end: try instant(m, date, to)),
            availability: availability
        )
    }

    private var scheduler: Scheduler {
        get throws { try Scheduler(timeZoneIdentifier: "Asia/Shanghai") }
    }

    // MARK: - Free time math

    @Test func defaultWindowsExcludeLunch() throws {
        let m = try math()
        let range = try dayRange(m, "2026-11-17") // Tuesday
        let slots = try scheduler.freeIntervals(in: ScheduleRequest(range: range, now: range.start, tasks: []))
        #expect(slots.count == 2)
        #expect(m.formatTime(slots[0].start) == "09:00")
        #expect(m.formatTime(slots[0].end) == "12:00")
        #expect(m.formatTime(slots[1].start) == "13:00")
        #expect(m.formatTime(slots[1].end) == "18:00")
    }

    @Test func weekendHasNoWorkingWindows() throws {
        let m = try math()
        let range = try dayRange(m, "2026-11-21") // Saturday
        let slots = try scheduler.freeIntervals(in: ScheduleRequest(range: range, now: range.start, tasks: []))
        #expect(slots.isEmpty)
    }

    @Test func adjacentAndOverlappingBusyBlocksMerge() throws {
        let m = try math()
        let range = try dayRange(m, "2026-11-17")
        let blocks = [
            try busy(m, "2026-11-17", "09:00", "10:00"),
            try busy(m, "2026-11-17", "10:00", "12:00"),
            try busy(m, "2026-11-17", "13:00", "15:30"),
            try busy(m, "2026-11-17", "15:00", "16:00"),
        ]
        let slots = try scheduler.freeIntervals(
            in: ScheduleRequest(range: range, now: range.start, tasks: [], busy: blocks)
        )
        #expect(slots.count == 1)
        #expect(m.formatTime(slots[0].start) == "16:00")
        #expect(m.formatTime(slots[0].end) == "18:00")
    }

    @Test func freeAvailabilityIsIgnored() throws {
        let m = try math()
        let range = try dayRange(m, "2026-11-17")
        let blocks = [try busy(m, "2026-11-17", "09:00", "11:00", availability: .free)]
        let slots = try scheduler.freeIntervals(
            in: ScheduleRequest(range: range, now: range.start, tasks: [], busy: blocks)
        )
        #expect(slots.count == 2)
    }

    @Test func unknownAvailabilityBlocksTime() throws {
        let m = try math()
        let range = try dayRange(m, "2026-11-17")
        let blocks = [try busy(m, "2026-11-17", "09:00", "12:00", availability: .unknown)]
        let slots = try scheduler.freeIntervals(
            in: ScheduleRequest(range: range, now: range.start, tasks: [], busy: blocks)
        )
        #expect(slots.count == 1)
        #expect(m.formatTime(slots[0].start) == "13:00")
    }

    @Test func allDayEventBlocksWholeDay() throws {
        let m = try math()
        let range = try dayRange(m, "2026-11-17")
        let allDay = BusyBlock(id: "allday", title: "conference", interval: range,
                               availability: .busy, isAllDay: true)
        let slots = try scheduler.freeIntervals(
            in: ScheduleRequest(range: range, now: range.start, tasks: [], busy: [allDay])
        )
        #expect(slots.isEmpty)
    }

    // MARK: - Placement

    @Test func longTaskSplitsAcrossDays() throws {
        let m = try math()
        let start = try instant(m, "2026-11-17", "00:00")
        let end = try instant(m, "2026-11-20", "00:00") // Tue..Thu
        let task = PlanTask(id: "t1", title: "write", estimatedMinutes: 600, priority: 3,
                            splittable: true, minChunkMinutes: 60)
        let plan = try scheduler.plan(
            ScheduleRequest(range: Interval(start: start, end: end), now: start, tasks: [task])
        )
        #expect(plan.assignments.reduce(0) { $0 + $1.minutes } == 600)
        #expect(plan.assignments.count >= 2)
        for assignment in plan.assignments {
            #expect(assignment.minutes <= 90)
            #expect(assignment.minutes >= 60)
        }
    }

    @Test func splitRespectsMinChunk() throws {
        let m = try math()
        let range = try dayRange(m, "2026-11-17")
        let blocks = [try busy(m, "2026-11-17", "09:00", "11:00")]
        let task = PlanTask(id: "t1", title: "review", estimatedMinutes: 240, priority: 3,
                            splittable: true, minChunkMinutes: 60)
        let plan = try scheduler.plan(
            ScheduleRequest(range: range, now: range.start, tasks: [task], busy: blocks)
        )
        #expect(plan.assignments.reduce(0) { $0 + $1.minutes } == 240)
        #expect(plan.assignments.count == 3)
        for assignment in plan.assignments {
            #expect(assignment.minutes >= 60)
        }
    }

    @Test func minChunkUnmetIsExplained() throws {
        let m = try math()
        let range = try dayRange(m, "2026-11-17")
        let blocks = [
            try busy(m, "2026-11-17", "09:00", "12:00"),
            try busy(m, "2026-11-17", "13:00", "17:30"),
        ]
        let task = PlanTask(id: "t1", title: "deep work", estimatedMinutes: 45, priority: 3,
                            splittable: true, minChunkMinutes: 60)
        let plan = try scheduler.plan(
            ScheduleRequest(range: range, now: range.start, tasks: [task], busy: blocks)
        )
        #expect(plan.assignments.isEmpty)
        let entry = try #require(plan.unscheduled.first)
        #expect(entry.taskID == "t1")
        #expect(entry.reason == .minChunkUnmet)
        #expect(entry.shortfallMinutes == 45)
    }

    @Test func oversizeTaskIsReportedNotDropped() throws {
        let m = try math()
        let range = try dayRange(m, "2026-11-17")
        let task = PlanTask(id: "t1", title: "urgent", estimatedMinutes: 330, priority: 1,
                            splittable: false, minChunkMinutes: 60)
        let plan = try scheduler.plan(
            ScheduleRequest(range: range, now: range.start, tasks: [task])
        )
        #expect(plan.assignments.isEmpty)
        let entry = try #require(plan.unscheduled.first)
        #expect(entry.reason == .noContiguousBlock)
        #expect(entry.shortfallMinutes == 330)
    }

    @Test func priorityWinsWhenCapacityIsScarce() throws {
        let m = try math()
        let range = try dayRange(m, "2026-11-17")
        let blocks = [
            try busy(m, "2026-11-17", "09:00", "11:00"),
            try busy(m, "2026-11-17", "13:00", "18:00"),
        ]
        let low = PlanTask(id: "low", title: "low", estimatedMinutes: 60, priority: 4)
        let high = PlanTask(id: "high", title: "high", estimatedMinutes: 60, priority: 1)
        let plan = try scheduler.plan(
            ScheduleRequest(range: range, now: range.start, tasks: [low, high], busy: blocks)
        )
        #expect(plan.assignments.map { $0.taskID } == ["high"])
        #expect(plan.unscheduled.map { $0.taskID } == ["low"])
        #expect(plan.unscheduled.first?.reason == .noFreeInterval)
    }

    @Test func dependencyOrdering() throws {
        let m = try math()
        let start = try instant(m, "2026-11-17", "00:00")
        let end = try instant(m, "2026-11-18", "00:00")
        let first = PlanTask(id: "a", title: "research", estimatedMinutes: 120, priority: 3,
                             splittable: false)
        let second = PlanTask(id: "b", title: "draft", estimatedMinutes: 120, priority: 3,
                              splittable: false, dependsOn: ["a"])
        let plan = try scheduler.plan(
            ScheduleRequest(range: Interval(start: start, end: end), now: start, tasks: [second, first])
        )
        let a = try #require(plan.assignments.first { $0.taskID == "a" })
        let b = try #require(plan.assignments.first { $0.taskID == "b" })
        #expect(b.interval.start >= a.interval.end)
    }

    @Test func dependencyCycleThrows() throws {
        let m = try math()
        let start = try instant(m, "2026-11-17", "00:00")
        let end = try instant(m, "2026-11-18", "00:00")
        let a = PlanTask(id: "a", title: "a", estimatedMinutes: 60, dependsOn: ["b"])
        let b = PlanTask(id: "b", title: "b", estimatedMinutes: 60, dependsOn: ["a"])
        do {
            _ = try scheduler.plan(
                ScheduleRequest(range: Interval(start: start, end: end), now: start, tasks: [a, b])
            )
            Issue.record("expected a dependency cycle error")
        } catch let error as SchedulerError {
            guard case .dependencyCycle(let ids) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(ids == ["a", "b"])
        }
    }

    // MARK: - Deadline buffer

    @Test func safetyBufferKeepsTaskBeforeDeadlineMinusOneWorkday() throws {
        let m = try math()
        let start = try instant(m, "2026-11-19", "00:00") // Thursday
        let end = try instant(m, "2026-11-21", "00:00")
        let task = PlanTask(
            id: "t1", title: "prepare slides", estimatedMinutes: 120, priority: 3,
            earliestStart: try instant(m, "2026-11-19", "14:00"),
            deadline: .instant(try instant(m, "2026-11-20", "18:00")),
            splittable: false
        )
        let plan = try scheduler.plan(
            ScheduleRequest(range: Interval(start: start, end: end), now: start, tasks: [task])
        )
        let assignment = try #require(plan.assignments.first)
        #expect(assignment.interval.end <= (try instant(m, "2026-11-19", "18:00")))
    }

    @Test func bufferIsRelaxedWithWarningWhenNecessary() throws {
        let m = try math()
        let start = try instant(m, "2026-11-19", "00:00")
        let end = try instant(m, "2026-11-21", "00:00")
        let task = PlanTask(
            id: "t1", title: "big chunk", estimatedMinutes: 180, priority: 3,
            earliestStart: try instant(m, "2026-11-19", "16:00"),
            deadline: .instant(try instant(m, "2026-11-20", "18:00")),
            splittable: false
        )
        let plan = try scheduler.plan(
            ScheduleRequest(range: Interval(start: start, end: end), now: start, tasks: [task])
        )
        #expect(plan.assignments.count == 1)
        #expect(plan.warnings.contains { $0.contains("relaxed") })
    }

    // MARK: - Determinism

    @Test func planningIsDeterministic() throws {
        let m = try math()
        let start = try instant(m, "2026-11-17", "00:00")
        let end = try instant(m, "2026-11-21", "00:00")
        let range = Interval(start: start, end: end)
        let tasks = [
            PlanTask(id: "c", title: "c", estimatedMinutes: 90, priority: 2, splittable: true, minChunkMinutes: 30),
            PlanTask(id: "a", title: "a", estimatedMinutes: 150, priority: 2, splittable: true, minChunkMinutes: 30),
            PlanTask(id: "b", title: "b", estimatedMinutes: 45, priority: 3, splittable: false),
        ]
        let local = try scheduler
        let first = try local.plan(ScheduleRequest(range: range, now: start, tasks: tasks))
        let second = try local.plan(ScheduleRequest(range: range, now: start, tasks: tasks))
        #expect(first.assignments == second.assignments)
        #expect(first.unscheduled == second.unscheduled)
        #expect(first.statistics == second.statistics)
    }

    // MARK: - Time zone correctness

    @Test func durationAcrossSpringForwardIsRealElapsedTime() throws {
        let m = try math("America/New_York")
        // 2026-03-08: clocks jump 02:00 → 03:00.
        let interval = Interval(
            start: try instant(m, "2026-03-08", "01:30"),
            end: try instant(m, "2026-03-08", "03:30")
        )
        #expect(abs(interval.duration - 3_600) < 0.5)
        #expect(interval.minutes == 60)
    }

    @Test func workWindowsAreCorrectOnADSTTransitionDay() throws {
        let m = try math("America/New_York")
        // 2026-03-08 is a Sunday; clocks jump from 02:00 to 03:00, so the day is 23 hours long.
        let range = Interval(
            start: try instant(m, "2026-03-08", "00:00"),
            end: try instant(m, "2026-03-09", "00:00")
        )
        let config = ScheduleConfig(
            timeZoneID: "America/New_York",
            weeklyWindows: [
                WeekdayWindows(weekday: 1, windows: [
                    DayWindow(start: LocalTime(hour: 1, minute: 0), end: LocalTime(hour: 4, minute: 0)),
                    DayWindow(start: LocalTime(hour: 9, minute: 0), end: LocalTime(hour: 11, minute: 0)),
                ])
            ]
        )
        let local = try Scheduler(timeZoneIdentifier: "America/New_York", config: config)
        let slots = local.freeIntervals(
            in: ScheduleRequest(range: range, now: range.start, tasks: [], config: config)
        )
        #expect(slots.count == 2)
        // 01:00 → 04:00 crosses the gap: only two real hours elapse.
        #expect(abs(slots[0].duration - 7_200) < 0.5)
        #expect(m.formatTime(slots[0].start) == "01:00")
        #expect(m.formatTime(slots[0].end) == "04:00")
        #expect(abs(slots[1].duration - 7_200) < 0.5)
        #expect(m.formatTime(slots[1].start) == "09:00")
    }

    @Test func datedDeadlineEndsAtLocalMidnight() throws {
        let m = try math()
        let deadline = Deadline.date(LocalDate(year: 2026, month: 11, day: 20))
        let end = try #require(m.deadlineInstant(deadline))
        #expect(m.formatInstant(end) == "2026-11-21T00:00:00+08:00")
    }

    @Test func dependencyMustBeFullyScheduled() throws {
        let m = try math()
        let day = try dayRange(m, "2026-11-17")
        let cutoff = try instant(m, "2026-11-17", "11:00")
        let a = PlanTask(id: "a", title: "prepare", estimatedMinutes: 180, deadline: .instant(cutoff))
        let b = PlanTask(id: "b", title: "submit", estimatedMinutes: 30, dependsOn: ["a"])
        let plan = try scheduler.plan(ScheduleRequest(range: day, now: day.start, tasks: [a, b]))
        #expect(plan.assignments.contains { $0.taskID == "a" })
        #expect(!plan.assignments.contains { $0.taskID == "b" })
        #expect(plan.unscheduled.first { $0.taskID == "b" }?.reason == .dependencyUnscheduled)
    }

    @Test func acceptsExactFitOutsideQuarterHourGrid() throws {
        let m = try math()
        let day = try dayRange(m, "2026-11-17")
        let occupancies = [
            try busy(m, "2026-11-17", "09:00", "11:00"),
            try busy(m, "2026-11-17", "13:00", "16:25"),
        ]
        let task = PlanTask(id: "t", title: "research", estimatedMinutes: 95, splittable: false)
        let plan = try scheduler.plan(ScheduleRequest(range: day, now: day.start, tasks: [task], busy: occupancies))
        let block = try #require(plan.assignments.first)
        #expect(m.formatTime(block.interval.start) == "16:25")
        #expect(m.formatTime(block.interval.end) == "18:00")
    }

    @Test func aWeekOfLeadTimeLeavesTimeBeforeDeadline() throws {
        let m = try math()
        let friday = try instant(m, "2026-11-20", "09:00")
        let deadline = try instant(m, "2026-11-27", "18:00")
        let task = PlanTask(id: "t", title: "research", estimatedMinutes: 120,
                            deadline: .instant(deadline), splittable: false, preference: .afternoon)
        let plan = try scheduler.plan(ScheduleRequest(
            range: Interval(start: friday, end: deadline), now: friday, tasks: [task]
        ))
        let block = try #require(plan.assignments.first)
        #expect(m.formatDay(block.interval.start) == "2026-11-23")
        #expect(block.minutes == 120)
    }

    @Test func freeTimeNeverStartsInThePast() throws {
        let m = try math()
        let day = try dayRange(m, "2026-11-17")
        let now = try instant(m, "2026-11-17", "16:00")
        let slots = try scheduler.freeIntervals(in: ScheduleRequest(range: day, now: now, tasks: []))
        #expect(slots.first?.start == now)
        #expect(slots.count == 1)
    }
}
