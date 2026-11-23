import AppleBridge
import Foundation
import MCP
import SchedulerCore
import SchedulerStore

/// Process-level configuration shared by the CLI and the MCP server.
public struct ToolRuntime: Sendable {
    public var timeZoneID: String
    public var storePath: String
    public var now: @Sendable () -> Date

    public init(
        timeZoneID: String = TimeZone.current.identifier,
        storePath: String = ToolRuntime.defaultStorePath,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.timeZoneID = timeZoneID
        self.storePath = storePath
        self.now = now
    }

    /// `~/Library/Application Support/CodexScheduler/plans.sqlite`, overridable with
    /// `CODEX_SCHEDULER_STORE` so tests and throw-away runs never touch real state.
    public static var defaultStorePath: String {
        if let override = ProcessInfo.processInfo.environment["CODEX_SCHEDULER_STORE"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CodexScheduler/plans.sqlite").path
    }
}

/// Implements the phase-1 tool surface on top of a read-only calendar source.
///
/// Data flows one way: the source is only ever asked questions, and the only write the
/// service performs is `plan.save` into its own SQLite file.
public final class CalendarToolService: @unchecked Sendable {
    private let source: any CalendarSource
    private let runtime: ToolRuntime
    public let managed: ManagedScheduleService?

    public init(source: any CalendarSource, runtime: ToolRuntime = ToolRuntime(),
                managedFactory: ((String) -> ManagedScheduleService)? = nil) {
        self.source = source
        self.runtime = runtime
        self.resolvedStorePath = StoreLocation.resolve(preferred: runtime.storePath)
        self.managed = managedFactory?(resolvedStorePath)
    }

    /// The store actually in use after resolving the runtime preference.
    public let resolvedStorePath: String

    public func call(_ name: String, _ raw: [String: Value]) async throws -> Value {
        let args = Args(raw)
        switch name {
        case "list_calendars":
            return try listCalendars(args)
        case "list_events":
            return try listEvents(args)
        case "list_reminders":
            return try await listReminders(args)
        case "find_free_slots":
            return try findFreeSlots(args)
        case "plan_tasks":
            return try planTasks(args)
        case "preview_schedule":
            if let managed, let id = args.string("plan_id"), let journal = try? managed.journal(id) {
                return try managed.presentation(journal)
            }
            return try await previewSchedule(args)
        default:
            guard let managed else { throw ToolInputError("unknown tool '\(name)'") }
            return try await manage(name, args: args, service: managed)
        }
    }

    // MARK: - list_calendars

    private func listCalendars(_ args: Args) throws -> Value {
        let kind = (args.string("kind") ?? "all").lowercased()
        guard ["event", "reminder", "all"].contains(kind) else {
            throw ToolInputError("'kind' must be one of event, reminder, all")
        }
        var items: [Value] = []
        var errors: [String: Value] = [:]
        if kind != "reminder" {
            do { items.append(contentsOf: try source.eventCalendars().map { try calendarValue($0, kind: "event") }) }
            catch {
                if kind != "all" { throw error }
                errors["event"] = .string(String(describing: error))
            }
        }
        if kind != "event" {
            do { items.append(contentsOf: try source.reminderCalendars().map { try calendarValue($0, kind: "reminder_list") }) }
            catch {
                if kind != "all" { throw error }
                errors["reminder"] = .string(String(describing: error))
            }
        }
        if errors.count == 2 { throw ToolInputError(errors.keys.sorted().compactMap { errors[$0]?.stringValue }.joined(separator: " / ")) }
        return .object([
            "count": .int(items.count),
            "calendars": .array(items),
            "complete": .bool(errors.isEmpty),
            "source_errors": .object(errors),
        ])
    }

    private func calendarValue(_ calendar: CalendarSummary, kind: String) throws -> Value {
        .object([
            "id": .string(calendar.id),
            "title": .string(calendar.title),
            "kind": .string(kind),
            "type": .string(calendar.kind),
            "source": .string(calendar.source),
            "editable": .bool(calendar.allowsContentModifications),
            "immutable": .bool(calendar.isImmutable),
        ])
    }

    // MARK: - list_events

    private func listEvents(_ args: Args) throws -> Value {
        let math = try makeMath(args)
        let interval = try range(args, startKey: "start", endKey: "end", math: math)
        let events = try source.events(
            from: interval.start,
            to: interval.end,
            calendarIDs: try selectedIDs(args, key: "calendar_ids")
        )
        return .object([
            "time_zone": .string(math.identifier),
            "range": rangeValue(interval, math: math),
            "count": .int(events.count),
            "events": .array(events.map { eventValue($0, math: math, includeNotes: args.bool("include_notes", default: false)) }),
        ])
    }

    private func eventValue(_ event: EventItem, math: CalendarMath, includeNotes: Bool) -> Value {
        var object: [String: Value] = [
            "id": .string(event.id),
            "title": .string(event.title),
            "start": .string(math.formatInstant(event.start)),
            "end": .string(math.formatInstant(event.end)),
            "date": .string(math.formatDay(event.start)),
            "start_time": .string(math.formatTime(event.start)),
            "end_time": .string(math.formatTime(event.end)),
            "is_all_day": .bool(event.isAllDay),
            "availability": .string(event.availability.rawValue),
            "blocks_scheduling": .bool(event.availability != .free),
            "calendar_id": .string(event.calendarID),
            "calendar_title": .string(event.calendarTitle),
            "is_recurring": .bool(event.isRecurring),
            "has_attendees": .bool(event.hasAttendees),
        ]
        if let original = event.originalOccurrence { object["original_occurrence"] = .string(math.formatInstant(original)) }
        if let zone = event.sourceTimeZoneID { object["source_time_zone"] = .string(zone) }
        if includeNotes, let notes = event.notes, !notes.isEmpty {
            object["notes"] = .string(notes)
        }
        return .object(object)
    }

    // MARK: - list_reminders

    private func listReminders(_ args: Args) async throws -> Value {
        let math = try makeMath(args)
        let limit = min(max(args.int("limit", default: 100), 1), 500)
        let offset = max(0, args.int("offset", default: 0))
        let dueFrom = try InstantParser.parseOptional(args.string("due_from"), role: .start, math: math)
        let dueTo = try InstantParser.parseOptional(args.string("due_to"), role: .end, math: math)
        let includeCompleted = args.bool("include_completed", default: false)
        if let dueFrom, let dueTo, dueFrom >= dueTo { throw ToolInputError("due_to must be later than due_from") }

        let all = try await source.reminders(
            includeCompleted: includeCompleted,
            dueFrom: dueFrom,
            dueTo: dueTo,
            listIDs: try selectedIDs(args, key: "list_ids")
        )
        let page = Array(all.dropFirst(offset).prefix(limit))
        let nextOffset = min(offset, all.count) + page.count
        return .object([
            "time_zone": .string(math.identifier),
            "include_completed": .bool(includeCompleted),
            "total": .int(all.count),
            "count": .int(page.count),
            "offset": .int(offset),
            "truncated": .bool(all.count > nextOffset),
            "next_offset": all.count > nextOffset ? .int(nextOffset) : .null,
            "reminders": .array(page.map { reminderValue($0, math: math, includeNotes: args.bool("include_notes", default: false)) }),
        ])
    }

    private func reminderValue(_ reminder: ReminderItem, math: CalendarMath, includeNotes: Bool) -> Value {
        var object: [String: Value] = [
            "id": .string(reminder.id),
            "title": .string(reminder.title),
            "list_id": .string(reminder.listID),
            "list_title": .string(reminder.listTitle),
            "is_completed": .bool(reminder.isCompleted),
            "has_due_time": .bool(reminder.hasDueTime),
            "priority": .int(reminder.priority),
            "scheduler_priority": .int(reminder.schedulerPriority),
            "is_recurring": .bool(reminder.isRecurring),
            "recurrence_frequencies": JSON.stringArray(reminder.recurrenceFrequencies),
            "has_alarms": .bool(reminder.hasAlarms),
            "absolute_alarms": JSON.stringArray(reminder.absoluteAlarms.map(math.formatInstant)),
        ]
        if let date = reminder.localDueDate {
            object["due_date"] = .string(date)
        } else if let due = reminder.dueDate {
            object["due_at"] = .string(math.formatInstant(due))
            object["due_date"] = .string(math.formatDay(due))
            if reminder.hasDueTime {
                object["due_time"] = .string(math.formatTime(due))
            }
        }
        if let completed = reminder.completionDate {
            object["completed_at"] = .string(math.formatInstant(completed))
        }
        if includeNotes, let notes = reminder.notes, !notes.isEmpty {
            object["notes"] = .string(notes)
        }
        return .object(object)
    }

    // MARK: - find_free_slots

    private func findFreeSlots(_ args: Args) throws -> Value {
        let math = try makeMath(args)
        let interval = try range(args, startKey: "start", endKey: "end", math: math)
        let minimumMinutes = max(args.int("minimum_minutes", default: 30), 1)
        let config = try makeConfig(args, math: math)
        let scheduler = try Scheduler(timeZoneIdentifier: math.identifier, config: config)

        let busy = try busyBlocks(args, interval: interval, math: math, useCalendarByDefault: true)
        let request = ScheduleRequest(range: interval, now: runtime.now(), tasks: [], busy: busy, config: config)
        let slots = scheduler.freeSlots(in: request, minimumMinutes: minimumMinutes)
        let windows = math.workWindows(in: interval, config: config)

        var object: [String: Value] = [
            "time_zone": .string(math.identifier),
            "range": rangeValue(interval, math: math),
            "minimum_minutes": .int(minimumMinutes),
            "count": .int(slots.count),
            "total_free_minutes": .int(IntervalOps.totalMinutes(slots)),
            "free_slots": .array(slots.map { slotValue($0, math: math) }),
            "calendar_checked": .bool(args.bool("use_calendar", default: true)),
            "work_windows": .array(windows.map { rangeValue($0, math: math) }),
            "assumptions": .array(assumptions(config: config, math: math).map { .string($0) }),
        ]
        if args.bool("include_excluded", default: true) {
            object["excluded"] = .array(excludedValue(busy, interval: interval, math: math))
        }
        return .object(object)
    }

    private func excludedValue(_ busy: [BusyBlock], interval: Interval, math: CalendarMath) -> [Value] {
        busy
            .filter { $0.interval.overlaps(interval) }
            .map { block in
                let reason = block.availability == .free
                    ? "availability_free_ignored"
                    : (block.isAllDay ? "all_day_busy" : "busy")
                return .object([
                    "title": .string(block.title),
                    "id": .string(block.id),
                    "date": .string(math.formatDay(block.interval.start)),
                    "start_time": .string(math.formatTime(block.interval.start)),
                    "end_time": .string(math.formatTime(block.interval.end)),
                    "availability": .string(block.availability.rawValue),
                    "is_all_day": .bool(block.isAllDay),
                    "reason": .string(reason),
                ])
            }
    }

    private func slotValue(_ interval: Interval, math: CalendarMath) -> Value {
        .object([
            "start": .string(math.formatInstant(interval.start)),
            "end": .string(math.formatInstant(interval.end)),
            "date": .string(math.formatDay(interval.start)),
            "start_time": .string(math.formatTime(interval.start)),
            "end_time": .string(math.formatTime(interval.end)),
            "minutes": .int(interval.minutes),
        ])
    }

    // MARK: - plan_tasks

    private func planTasks(_ args: Args) throws -> Value {
        let math = try makeMath(args)
        let interval = try range(args, startKey: "range_start", endKey: "range_end", math: math)
        let config = try makeConfig(args, math: math)
        let tasks = try parseTasks(args, math: math, defaultMinChunk: config.minChunkMinutes)
        guard !tasks.isEmpty else {
            throw ToolInputError("'tasks' must contain at least one task")
        }
        let busy = try busyBlocks(args, interval: interval, math: math, useCalendarByDefault: true)

        let scheduler = try Scheduler(timeZoneIdentifier: math.identifier, config: config)
        let request = ScheduleRequest(range: interval, now: runtime.now(), tasks: tasks, busy: busy, config: config)
        var plan = try scheduler.plan(request)
        if !args.bool("use_calendar", default: true) {
            plan.warnings.append("本计划仅根据提供的占用数据排定，生成时未读取日历。")
        }
        let store = try openStore()
        try store.save(PlanRecord(plan: plan, tasks: tasks))

        return planValue(plan, tasks: tasks, math: math, saved: true)
    }

    private func parseTasks(_ args: Args, math: CalendarMath, defaultMinChunk: Int) throws -> [PlanTask] {
        guard let rawTasks = args.array("tasks") else {
            throw ToolInputError("missing required array argument 'tasks'")
        }
        var tasks: [PlanTask] = []
        var seen = Set<String>()
        for (index, raw) in rawTasks.enumerated() {
            let taskArgs = Args(raw.objectValue)
            let path = "tasks[\(index)]"
            let title = try taskArgs.requiredString("title")
            guard let estimated = taskArgs.int("estimated_minutes"), estimated > 0 else {
                throw ToolInputError("\(path).estimated_minutes must be a positive integer")
            }
            let id = taskArgs.string("id") ?? "task-\(index + 1)"
            guard seen.insert(id).inserted else {
                throw ToolInputError("duplicate task id '\(id)'")
            }
            let priority = min(max(taskArgs.int("priority", default: 3), 1), 5)
            let remaining = taskArgs.int("remaining_minutes").map { max(0, $0) }
            let earliest = try InstantParser.parseOptional(taskArgs.string("earliest_start"), role: .start, math: math)
            let deadline = try taskArgs.string("deadline").map { try InstantParser.parseDeadline($0, math: math) }
            let preference = TaskPreference(rawValue: taskArgs.string("preference") ?? "any") ?? .any
            let source = TaskSource(rawValue: taskArgs.string("source") ?? "user_request") ?? .userRequest
            tasks.append(
                PlanTask(
                    id: id,
                    title: title,
                    source: source,
                    estimatedMinutes: estimated,
                    remainingMinutes: remaining,
                    priority: priority,
                    earliestStart: earliest,
                    deadline: deadline,
                    splittable: taskArgs.bool("splittable", default: true),
                    minChunkMinutes: max(5, taskArgs.int("min_chunk_minutes", default: defaultMinChunk)),
                    preference: preference,
                    status: .pending,
                    dependsOn: taskArgs.stringArray("depends_on") ?? [],
                    allowConcurrentWith: taskArgs.stringArray("allow_concurrent_with") ?? [],
                    notes: taskArgs.string("notes")
                )
            )
        }
        return tasks
    }

    private func planValue(_ plan: SchedulePlan, tasks: [PlanTask], math: CalendarMath, saved: Bool) -> Value {
        let titles = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.title) })
        let assignments = plan.assignments.map { assignment -> Value in
            .object([
                "task_id": .string(assignment.taskID),
                "title": .string(titles[assignment.taskID] ?? assignment.taskID),
                "date": .string(math.formatDay(assignment.interval.start)),
                "start_time": .string(math.formatTime(assignment.interval.start)),
                "end_time": .string(math.formatTime(assignment.interval.end)),
                "start": .string(math.formatInstant(assignment.interval.start)),
                "end": .string(math.formatInstant(assignment.interval.end)),
                "minutes": .int(assignment.minutes),
                "chunk_index": .int(assignment.chunkIndex),
                "split_count": .int(assignment.splitCount),
                "display": .string(
                    "\(math.formatDay(assignment.interval.start)) \(math.formatTime(assignment.interval.start))–\(math.formatTime(assignment.interval.end))  \(titles[assignment.taskID] ?? assignment.taskID)"
                ),
            ])
        }
        let unscheduled = plan.unscheduled.map { item -> Value in
            .object([
                "task_id": .string(item.taskID),
                "title": .string(item.title),
                "reason": .string(item.reason.rawValue),
                "detail": .string(item.detail),
                "shortfall_minutes": .int(item.shortfallMinutes),
            ])
        }
        let statistics = plan.statistics
        return .object([
            "plan_id": .string(plan.planID),
            "time_zone": .string(plan.timeZoneID),
            "generated_at": .string(math.formatInstant(plan.generatedAt)),
            "range": rangeValue(Interval(start: plan.rangeStart, end: plan.rangeEnd), math: math),
            "saved": .bool(saved),
            "assignments": .array(assignments),
            "unscheduled": .array(unscheduled),
            "statistics": .object([
                "total_window_minutes": .int(statistics.totalWindowMinutes),
                "busy_minutes": .int(statistics.busyMinutes),
                "free_minutes": .int(statistics.freeMinutes),
                "allocated_minutes": .int(statistics.allocatedMinutes),
                "utilization": .double(statistics.utilization),
                "task_count": .int(statistics.taskCount),
                "scheduled_task_count": .int(statistics.scheduledTaskCount),
            ]),
            "assumptions": .array(plan.assumptions.map { .string($0) }),
            "warnings": .array(plan.warnings.map { .string($0) }),
            "free_minutes_remaining": .int(max(0, statistics.freeMinutes - statistics.allocatedMinutes)),
        ])
    }

    // MARK: - preview_schedule

    private func previewSchedule(_ args: Args) async throws -> Value {
        let planID = try args.requiredString("plan_id")
        let store = try openStore()
        guard let record = try store.load(planID: planID) else {
            throw ToolInputError("no stored plan with id '\(planID)'; run plan_tasks first")
        }
        let plan = record.plan
        let math = try CalendarMath(timeZoneIdentifier: args.string("time_zone") ?? plan.timeZoneID)
        let range = Interval(start: plan.rangeStart, end: plan.rangeEnd)
        let taskTitles = Dictionary(uniqueKeysWithValues: record.tasks.map { ($0.id, $0.title) })

        // Re-read the calendar: a plan is a snapshot, and the preview must say whether the
        // snapshot still matches reality. This read cannot change anything.
        //
        // Both failures are recoverable: `use_calendar: false` is for callers that already
        // know the busy time, and a machine without calendar permission should still get a
        // usable preview. Either way the output states that conflicts were not checked, so a
        // "no conflicts" reading can never be mistaken for a verified one.
        var currentEvents: [EventItem] = []
        var conflictCheck = "checked_against_calendar"
        var previewWarnings = plan.warnings
        if args.bool("use_calendar", default: true) {
            do {
                currentEvents = try source.events(from: range.start, to: range.end, calendarIDs: nil)
            } catch let error as EventKitError {
                conflictCheck = "skipped_permission_denied"
                previewWarnings.append("未能读取日历，冲突检查已跳过：\(error.description)")
            }
        } else {
            conflictCheck = "skipped_by_request"
            previewWarnings.append("调用方要求跳过日历读取，冲突检查未执行。")
        }

        var operations: [Value] = []
        var conflicts: [Value] = []
        for assignment in plan.assignments {
            let overlap = currentEvents.first { event in
                event.availability != .free && event.start < assignment.interval.end && assignment.interval.start < event.end
            }
            operations.append(
                .object([
                    "op": .string("create_time_block"),
                    "task_id": .string(assignment.taskID),
                    "title": .string(taskTitles[assignment.taskID] ?? assignment.taskID),
                    "date": .string(math.formatDay(assignment.interval.start)),
                    "start_time": .string(math.formatTime(assignment.interval.start)),
                    "end_time": .string(math.formatTime(assignment.interval.end)),
                    "minutes": .int(assignment.minutes),
                    "target_calendar": .string("AI 日程安排"),
                    "reason": .string(
                        "为任务 \(assignment.taskID) 安排第 \(assignment.chunkIndex + 1)/\(assignment.splitCount) 段共 \(assignment.minutes) 分钟"
                    ),
                ])
            )
            if let overlap {
                conflicts.append(
                    .object([
                        "task_id": .string(assignment.taskID),
                        "kind": .string("overlaps_calendar_event"),
                        "detail": .string(
                            "计划时段与现有日程「\(overlap.title)」重叠（\(math.formatDay(overlap.start)) \(math.formatTime(overlap.start))–\(math.formatTime(overlap.end))）"
                        ),
                    ])
                )
            }
        }

        let totalMinutes = plan.assignments.reduce(0) { $0 + $1.minutes }
        let expiresAt = runtime.now().addingTimeInterval(30 * 60)
        var preview: [String: Value] = [
            "plan_id": .string(plan.planID),
            "time_zone": .string(math.identifier),
            "generated_at": .string(math.formatInstant(plan.generatedAt)),
            "range": rangeValue(range, math: math),
            "summary": .object([
                "blocks": .int(plan.assignments.count),
                "tasks": .int(record.tasks.count),
                "total_minutes": .int(totalMinutes),
                "unscheduled_tasks": .int(plan.unscheduled.count),
                "conflicts": .int(conflicts.count),
                "headline": .string(
                    "\(math.formatDay(range.start)) 至 \(math.formatDay(range.end.addingTimeInterval(-1))): "
                        + "\(plan.assignments.count) 个时间块，共 \(totalMinutes) 分钟，"
                        + "\(plan.unscheduled.count) 个任务排不下"
                ),
            ]),
            "operations": .array(operations),
            "conflicts": .array(conflicts),
            "conflict_check": .string(conflictCheck),
            "unscheduled": .array(plan.unscheduled.map { item in
                .object([
                    "task_id": .string(item.taskID),
                    "title": .string(item.title),
                    "reason": .string(item.reason.rawValue),
                    "detail": .string(item.detail),
                    "shortfall_minutes": .int(item.shortfallMinutes),
                ])
            }),
            "authorization": .object([
                "scope": .string("read_only_preview"),
                "write_performed": .bool(false),
                "requires_human_confirmation": .bool(false),
                "commit_available": .bool(false),
                "expires_at": .string(math.formatInstant(expiresAt)),
                "note": .string("提交需要完成日历冲突检查，并且至少有一个可写入的时间块。"),
            ]),
            "assumptions": .array(plan.assumptions.map { .string($0) }),
            "warnings": .array(previewWarnings.map { .string($0) }),
        ]
        if let managed, conflictCheck == "checked_against_calendar", conflicts.isEmpty, !plan.assignments.isEmpty {
            let draft = try await managed.reservePlan(plan, tasks: record.tasks, reminders: [])
            preview["writeback"] = draft
            preview["authorization"] = .object([
                "scope": .string("chat_confirmation"),
                "write_performed": .bool(false), "commit_available": .bool(true),
                "requires_human_confirmation": .bool(true),
            ])
        }
        return .object(preview)
    }

    private func manage(_ tool: String, args: Args, service: ManagedScheduleService) async throws -> Value {
        let math = try makeMath(args)
        switch tool {
        case "schedule_status":
            return try service.presentation(service.journal(args.requiredString("plan_id")))
        case "list_managed_items":
            let entries = try service.items()
            return .object([
                "items": .array(entries.map { service.itemValue($0, math: math) }),
                "completed_task_ids": JSON.stringArray(try Set(entries.map(\.taskID)).sorted().filter { try service.isTaskComplete($0) }),
            ])
        case "propose_reminder":
            let title = try args.requiredString("title")
            let time = try InstantParser.parse(try args.requiredString("remind_at"), role: .start, math: math)
            guard args.string("remind_at")?.contains(":") == true, time > runtime.now() else {
                throw ToolInputError("提醒时间须为未来的具体时刻")
            }
            let id = UUID().uuidString
            let taskID = args.string("task_id") ?? id
            if taskID != id, try !service.items().contains(where: { $0.taskID == taskID }) {
                throw ToolInputError("找不到要关联的自管任务")
            }
            let reminder = ManagedItem(id: id, taskID: taskID, kind: .reminder, title: title, start: service.seconds(time))
            return try service.draft([ScheduleChange(after: reminder)], zone: math.identifier)
        case "reschedule":
            let id = try args.requiredString("item_id")
            guard let item = try service.items().first(where: { $0.id == id }), !item.completed,
                  try !service.isTaskComplete(item.taskID) else {
                throw ToolInputError("找不到可重排的自管事项")
            }
            var proposed = item
            if let text = args.string("start") {
                guard text.contains(":") else { throw ToolInputError("请提供具体开始时刻") }
                proposed.start = service.seconds(try InstantParser.parse(text, role: .start, math: math))
                if let end = item.end { proposed.end = proposed.start.addingTimeInterval(end.timeIntervalSince(item.start)) }
            } else if let end = item.end {
                let window = try range(args, startKey: "range_start", endKey: "range_end", math: math)
                let minutes = Int(end.timeIntervalSince(item.start) / 60)
                let config = try makeConfig(args, math: math)
                let extra = try busyBlocks(args, interval: window, math: math, useCalendarByDefault: false,
                                           alwaysSkipCalendar: true)
                let live = try source.events(from: window.start, to: window.end, calendarIDs: nil)
                    .filter { $0.notes != item.marker || $0.start != item.start || $0.end != item.end }
                let suppliedDeadline = try args.string("deadline").map { try InstantParser.parseDeadline($0, math: math) }
                    .flatMap(math.deadlineInstant)
                let limit = [item.latestAllowed, suppliedDeadline].compactMap { $0 }.min()
                let task = PlanTask(id: id, title: item.title, estimatedMinutes: minutes,
                                    earliestStart: item.earliestAllowed, deadline: limit.map(Deadline.instant),
                                    splittable: false)
                let vars = ScheduleRequest(range: window, now: runtime.now(), tasks: [task],
                                           busy: live.map(\.busyBlock) + extra, config: config)
                let alternative = try Scheduler(timeZoneIdentifier: math.identifier, config: config).plan(vars)
                guard let slot = alternative.assignments.first else {
                    throw ToolInputError(alternative.unscheduled.first?.detail ?? "找不到可用时段")
                }
                proposed.start = service.seconds(slot.interval.start)
                proposed.end = service.seconds(slot.interval.end)
            } else {
                throw ToolInputError("改期提醒时需要指定新的具体时刻")
            }
            guard proposed != item, proposed.start > runtime.now() else { throw ToolInputError("请选择新的未来时段") }
            return try service.draft([ScheduleChange(before: item, after: proposed)], zone: math.identifier)
        case "complete_task":
            let id = try args.requiredString("task_id")
            let items = try service.items().filter { $0.taskID == id }
            guard !items.isEmpty, try !service.isTaskComplete(id) else { throw ToolInputError("找不到未完成的自管任务") }
            let changes: [ScheduleChange] = items.compactMap {
                if $0.kind == .event { return $0.start > runtime.now() ? ScheduleChange(before: $0) : nil }
                if $0.completed { return nil }
                var done = $0
                done.completed = true
                return ScheduleChange(before: $0, after: done)
            }
            return try service.draft(changes, zone: math.identifier,
                                     taskCompletion: TaskCompletionChange(taskID: id, before: false, after: true))
        case "undo_schedule":
            return try service.undo(args.requiredString("plan_id"), zone: math.identifier)
        default:
            throw ToolInputError("unknown tool '\(tool)'")
        }
    }

    // MARK: - Shared plumbing

    private func makeMath(_ args: Args) throws -> CalendarMath {
        let identifier = args.string("time_zone") ?? runtime.timeZoneID
        do {
            return try CalendarMath(timeZoneIdentifier: identifier)
        } catch {
            throw ToolInputError("invalid time zone '\(identifier)'")
        }
    }

    private func makeConfig(_ args: Args, math: CalendarMath) throws -> ScheduleConfig {
        var config = ScheduleConfig.default
        config.timeZoneID = math.identifier
        if let granularity = args.int("granularity_minutes") { config.granularityMinutes = max(5, granularity) }
        if let buffer = args.int("buffer_workdays") { config.bufferWorkdays = max(0, buffer) }
        if let position = args.double("target_position"), position.isFinite { config.targetPosition = min(max(position, 0), 1) }
        if let session = args.int("max_session_minutes") { config.maxSessionMinutes = max(15, session) }
        if let chunk = args.int("min_chunk_minutes") { config.minChunkMinutes = max(5, chunk) }
        if let windows = args.array("working_windows") {
            var grouped: [Int: [DayWindow]] = [:]
            for value in windows {
                let entry = Args(value.objectValue)
                let weekday = try entry.requiredInt("weekday")
                let start = try parseLocalTime(entry.requiredString("start"))
                let end = try parseLocalTime(entry.requiredString("end"))
                guard (1...7).contains(weekday), start < end else {
                    throw ToolInputError("working_windows requires a weekday 1–7 and a same-day start before end")
                }
                grouped[weekday, default: []].append(DayWindow(start: start, end: end))
            }
            config.weeklyWindows = grouped.keys.sorted().map { WeekdayWindows(weekday: $0, windows: grouped[$0] ?? []) }
        }
        return config
    }

    private func parseLocalTime(_ text: String) throws -> LocalTime {
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, fields.allSatisfy({ $0.count == 2 }),
              let hour = Int(fields[0]), let minute = Int(fields[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            throw ToolInputError("invalid working time '\(text)'; use HH:mm")
        }
        return LocalTime(hour: hour, minute: minute)
    }

    private func range(_ args: Args, startKey: String, endKey: String, math: CalendarMath) throws -> Interval {
        let start = try InstantParser.parseOptional(args.string(startKey), role: .start, math: math) ?? runtime.now()
        let end = try InstantParser.parseOptional(args.string(endKey), role: .end, math: math)
            ?? math.calendar.date(byAdding: .day, value: 7, to: start)
            ?? start.addingTimeInterval(7 * 86_400)
        guard end > start else {
            throw ToolInputError("'\(endKey)' must be later than '\(startKey)'")
        }
        guard end.timeIntervalSince(start) <= 400 * 24 * 3600 else {
            throw ToolInputError("requested range is longer than 400 days; narrow it down")
        }
        return Interval(start: start, end: end)
    }

    private func rangeValue(_ interval: Interval, math: CalendarMath) -> Value {
        .object([
            "start": .string(math.formatInstant(interval.start)),
            "end": .string(math.formatInstant(interval.end)),
            "start_date": .string(math.formatDay(interval.start)),
            "end_date": .string(math.formatDay(interval.end.addingTimeInterval(-1))),
            "minutes": .int(interval.minutes),
        ])
    }

    private func busyBlocks(_ args: Args, interval: Interval, math: CalendarMath, useCalendarByDefault: Bool,
                            alwaysSkipCalendar: Bool = false) throws -> [BusyBlock] {
        var busy: [BusyBlock] = []
        if !alwaysSkipCalendar && args.bool("use_calendar", default: useCalendarByDefault) {
            let events = try source.events(from: interval.start, to: interval.end, calendarIDs: selectedIDs(args, key: "calendar_ids"))
            busy.append(contentsOf: events.map { $0.busyBlock })
        }
        if let extra = args.array("busy_blocks") {
            for (index, raw) in extra.enumerated() {
                let item = Args(raw.objectValue)
                let path = "busy_blocks[\(index)]"
                let title = try item.requiredString("title")
                let start = try InstantParser.parse(try item.requiredString("start"), role: .start, math: math)
                let end = try InstantParser.parse(try item.requiredString("end"), role: .end, math: math)
                guard end > start else { throw ToolInputError("\(path).end must be later than \(path).start") }
                let availability = Availability(rawValue: item.string("availability") ?? "busy") ?? .busy
                busy.append(
                    BusyBlock(
                        id: "extra-\(index + 1)",
                        title: title,
                        interval: Interval(start: start, end: end),
                        availability: availability
                    )
                )
            }
        }
        return busy
    }

    private func selectedIDs(_ args: Args, key: String) throws -> [String]? {
        guard let value = args.value(key) else { return nil }
        guard let items = value.arrayValue, !items.isEmpty else {
            throw ToolInputError("'\(key)' must be a non-empty array of identifiers")
        }
        let identifiers = items.compactMap(\.stringValue)
        guard identifiers.count == items.count, identifiers.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw ToolInputError("'\(key)' contains an invalid identifier")
        }
        return identifiers
    }

    private func assumptions(config: ScheduleConfig, math: CalendarMath) -> [String] {
        var lines = [
            "时区 \(math.identifier)；工作窗口按配置的每周窗口计算，非工作日不排弹性任务。",
            "忙碌判断：日历事件中 availability 为 free 视为不占用，其余（含未知）一律视为占用。",
            "优先级 1 最高、5 最低；截止前保留 \(config.bufferWorkdays) 个工作日的安全余量（优先级 ≥2 生效）。",
        ]
        let weekdays = config.weeklyWindows
            .filter { !$0.windows.isEmpty }
            .map { entry -> String in
                let names = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
                let name = (1...7).contains(entry.weekday) ? names[entry.weekday] : "第\(entry.weekday)天"
                let windows = entry.windows.map { "\($0.start)–\($0.end)" }.joined(separator: "、")
                return "\(name) \(windows)"
            }
        if !weekdays.isEmpty {
            lines.append("可用窗口：" + weekdays.joined(separator: "；") + "。")
        } else {
            lines.append("当前配置没有任何可用工作窗口，所有任务都会被判定为排不下。")
        }
        return lines
    }

    private func openStore() throws -> PlanStore {
        try PlanStore(path: resolvedStorePath)
    }
}
