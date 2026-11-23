import Foundation

/// Input for one scheduling run.
public struct ScheduleRequest: Sendable {
    public var range: Interval
    public var now: Date
    public var tasks: [PlanTask]
    public var busy: [BusyBlock]
    public var locked: [LockedBlock]
    public var config: ScheduleConfig

    public init(
        range: Interval,
        now: Date,
        tasks: [PlanTask],
        busy: [BusyBlock] = [],
        locked: [LockedBlock] = [],
        config: ScheduleConfig = .default
    ) {
        self.range = range
        self.now = now
        self.tasks = tasks
        self.busy = busy
        self.locked = locked
        self.config = config
    }
}

/// Deterministic, explainable placement engine.
///
/// Properties guaranteed by design:
/// * identical input produces identical output (no randomness, total ordering everywhere);
/// * every planned block is aligned to the local grid and stays inside the configured
///   working windows after removing busy time and locked blocks;
/// * every task that cannot be fully placed is reported with a reason and a shortfall.
public struct Scheduler: Sendable {
    public let math: CalendarMath
    public let config: ScheduleConfig

    public init(timeZoneIdentifier: String, config: ScheduleConfig = .default) throws {
        self.math = try CalendarMath(timeZoneIdentifier: timeZoneIdentifier)
        self.config = config
    }

    // MARK: - Free time

    /// Working windows minus busy blocks minus locked blocks, in local time.
    public func freeIntervals(in request: ScheduleRequest) -> [Interval] {
        let future = Interval(start: max(request.range.start, request.now), end: request.range.end)
        guard !future.isEmpty else { return [] }
        let windows = math.workWindows(in: future, config: request.config)
        var blocked: [Interval] = []
        blocked.append(contentsOf: request.busy.filter { $0.blocksScheduling }.map { $0.interval })
        blocked.append(contentsOf: request.locked.map { $0.interval })
        return IntervalOps.subtract(windows, blocked)
    }

    /// Free slots of at least `minimumMinutes`, optionally restricted to a sub-range.
    public func freeSlots(
        in request: ScheduleRequest,
        minimumMinutes: Int,
        from: Date? = nil,
        to: Date? = nil
    ) -> [Interval] {
        var slots = freeIntervals(in: request)
        if let from = from, let to = to {
            slots = IntervalOps.clamp(slots, to: Interval(start: from, end: to))
        } else if let from = from {
            slots = IntervalOps.clamp(slots, to: Interval(start: from, end: request.range.end))
        } else if let to = to {
            slots = IntervalOps.clamp(slots, to: Interval(start: request.range.start, end: to))
        }
        return IntervalOps.filtering(slots, minimumMinutes: minimumMinutes)
    }

    // MARK: - Plan

    public func plan(_ request: ScheduleRequest) throws -> SchedulePlan {
        let config = request.config
        let aligner = GridAligner(math: math, minutes: config.granularityMinutes)
        let ordered = try ordering(request.tasks)

        let future = Interval(start: max(request.range.start, request.now), end: request.range.end)
        let windows = future.isEmpty ? [] : math.workWindows(in: future, config: config)
        var blocked: [Interval] = []
        blocked.append(contentsOf: request.busy.filter { $0.blocksScheduling }.map { $0.interval })
        blocked.append(contentsOf: request.locked.map { $0.interval })
        let freeBase = IntervalOps.subtract(windows, blocked)

        var assignmentsByTask: [String: [Interval]] = [:]
        var chunkCounts: [String: Int] = [:]
        var assignedMinutes: [String: Int] = [:]
        var placedEnd: [String: Date] = [:]
        var unscheduledIDs: Set<String> = []
        var unscheduled: [UnscheduledTask] = []
        var warnings: [String] = []

        // Tasks already committed by a previous run stay where they are.
        var lockedByTask: [String: [Interval]] = [:]
        for block in request.locked {
            lockedByTask[block.taskID, default: []].append(block.interval)
        }
        let taskStatus = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.status) })

        func occupiedByOthers(than taskID: String) -> [Interval] {
            var occupied: [Interval] = []
            for (otherID, intervals) in assignmentsByTask where otherID != taskID {
                if !isMutuallyConcurrent(taskID, otherID, tasks: request.tasks) {
                    occupied.append(contentsOf: intervals)
                }
            }
            return occupied
        }

        for task in ordered {
            guard task.status == .pending else { continue }
            if task.remainingMinutes == 0 { continue }
            if let locked = lockedByTask[task.id], !locked.isEmpty {
                assignmentsByTask[task.id] = locked
                placedEnd[task.id] = locked.map { $0.end }.max()
                chunkCounts[task.id] = locked.count
                assignedMinutes[task.id] = IntervalOps.totalMinutes(locked)
                continue
            }

            if let failedDependency = task.dependsOn.first(where: {
                if taskStatus[$0] == .done { return false }
                return unscheduledIDs.contains($0) || placedEnd[$0] == nil
            }) {
                unscheduledIDs.insert(task.id)
                unscheduled.append(UnscheduledTask(
                    taskID: task.id,
                    title: task.title,
                    reason: .dependencyUnscheduled,
                    detail: "dependency \(failedDependency) could not be scheduled",
                    shortfallMinutes: max(0, task.remainingMinutes)
                ))
                continue
            }

            var earliest = max(request.now, request.range.start)
            if let explicit = task.earliestStart { earliest = max(earliest, explicit) }
            for dependency in task.dependsOn {
                if let end = placedEnd[dependency] { earliest = max(earliest, end) }
            }

            let deadline = task.deadline.flatMap(math.deadlineInstant)
            let latest = min(request.range.end, deadline ?? request.range.end)

            guard latest > earliest else {
                unscheduledIDs.insert(task.id)
                let deadlinePassed = deadline.map { $0 <= earliest } ?? false
                let detail = deadlinePassed
                    ? "deadline \(math.formatInstant(latest)) is at or before the earliest possible start \(math.formatInstant(earliest))"
                    : "the planning window ends before this task can start"
                unscheduled.append(UnscheduledTask(
                    taskID: task.id,
                    title: task.title,
                    reason: deadlinePassed ? .deadlinePassed : .noFreeInterval,
                    detail: detail,
                    shortfallMinutes: max(0, task.remainingMinutes)
                ))
                continue
            }

            // Priority 1 tasks ignore the safety buffer; everyone else keeps it when possible.
            let bufferDays = (deadline != nil && task.priority >= 2) ? max(0, config.bufferWorkdays) : 0
            let bufferedLatest = deadline.map {
                min(latest, math.subtractingWorkdays(bufferDays, from: $0, config: config))
            } ?? latest
            let ideal = earliest.addingTimeInterval(latest.timeIntervalSince(earliest) * config.targetPosition)

            let pool = { (deadline: Date) -> [Interval] in
                IntervalOps.subtract(freeBase, occupiedByOthers(than: task.id))
                    .compactMap { $0.intersection(Interval(start: earliest, end: deadline)) }
                    .filter { $0.minutes > 0 }
            }

            var placed = try place(
                task: task,
                earliest: earliest,
                latest: bufferedLatest,
                ideal: ideal,
                pool: pool(bufferedLatest),
                aligner: aligner
            )

            if placed.shortfallMinutes > 0 && bufferedLatest < latest {
                let relaxed = try place(
                    task: task,
                    earliest: earliest,
                    latest: latest,
                    ideal: ideal,
                    pool: pool(latest),
                    aligner: aligner
                )
                if relaxed.assignedMinutes > placed.assignedMinutes {
                    warnings.append("relaxed the \(bufferDays)-workday safety buffer for \(task.id) (\(task.title))")
                    placed = relaxed
                }
            }

            if placed.intervals.isEmpty {
                unscheduledIDs.insert(task.id)
                unscheduled.append(UnscheduledTask(
                    taskID: task.id,
                    title: task.title,
                    reason: placed.emptyReason,
                    detail: placed.explanation,
                    shortfallMinutes: placed.shortfallMinutes
                ))
                continue
            }

            assignmentsByTask[task.id] = placed.intervals
            chunkCounts[task.id] = placed.intervals.count
            assignedMinutes[task.id] = placed.assignedMinutes
            placedEnd[task.id] = placed.intervals.map { $0.end }.max()

            if placed.shortfallMinutes > 0 {
                unscheduledIDs.insert(task.id)
                unscheduled.append(UnscheduledTask(
                    taskID: task.id,
                    title: task.title,
                    reason: placed.shortfallReason,
                    detail: placed.explanation,
                    shortfallMinutes: placed.shortfallMinutes
                ))
            }
            if placed.forcedAlignment {
                warnings.append("\(task.id) could not be aligned to the \(config.granularityMinutes)-minute grid without overrunning a window")
            }
        }

        // Flatten into a stable, readable order.
        var assignments: [Assignment] = []
        for task in ordered {
            guard let intervals = assignmentsByTask[task.id] else { continue }
            let sorted = intervals.sorted()
            for (index, interval) in sorted.enumerated() {
                assignments.append(Assignment(
                    taskID: task.id,
                    interval: interval,
                    minutes: interval.minutes,
                    chunkIndex: index,
                    splitCount: sorted.count
                ))
            }
        }
        assignments.sort {
            $0.interval == $1.interval ? $0.taskID < $1.taskID : $0.interval < $1.interval
        }

        let taken = assignments.filter { lockedByTask[$0.taskID] == nil }.map(\.interval)
        let totalAllocated = IntervalOps.totalMinutes(taken)
        let freeMinutes = IntervalOps.totalMinutes(freeBase)
        let windowMinutes = IntervalOps.totalMinutes(windows)
        let statistics = ScheduleStatistics(
            totalWindowMinutes: windowMinutes,
            busyMinutes: max(0, windowMinutes - freeMinutes),
            freeMinutes: freeMinutes,
            allocatedMinutes: totalAllocated,
            utilization: freeMinutes > 0 ? Double(totalAllocated) / Double(freeMinutes) : 0,
            taskCount: request.tasks.filter { $0.status == .pending }.count,
            scheduledTaskCount: assignmentsByTask.keys.filter { !unscheduledIDs.contains($0) }.count
        )

        return SchedulePlan(
            planID: UUID().uuidString,
            generatedAt: request.now,
            rangeStart: request.range.start,
            rangeEnd: request.range.end,
            timeZoneID: math.identifier,
            assignments: assignments,
            unscheduled: unscheduled.sorted { $0.taskID < $1.taskID },
            freeIntervals: freeBase,
            statistics: statistics,
            assumptions: assumptions(range: request.range),
            warnings: warnings
        )
    }

    // MARK: - Placement internals

    private struct PlacementResult {
        var intervals: [Interval] = []
        var assignedMinutes: Int = 0
        var shortfallMinutes: Int = 0
        var shortfallReason: UnscheduledReason = .insufficientTotalTime
        var emptyReason: UnscheduledReason = .noFreeInterval
        var explanation: String = ""
        var forcedAlignment: Bool = false
    }

    private func place(
        task: PlanTask,
        earliest: Date,
        latest: Date,
        ideal: Date,
        pool: [Interval],
        aligner: GridAligner
    ) throws -> PlacementResult {
        var result = PlacementResult()
        var remaining = max(0, task.remainingMinutes)
        result.shortfallMinutes = remaining
        guard remaining > 0 else { result.shortfallMinutes = 0; return result }

        let roomMinutes = IntervalOps.totalMinutes(IntervalOps.clamp(pool, to: Interval(start: earliest, end: latest)))
        let minimumChunk = max(1, min(task.minChunkMinutes, remaining))

        guard roomMinutes > 0 else {
            result.emptyReason = .noFreeInterval
            result.explanation = "no free time inside the allowed window"
            return result
        }
        guard roomMinutes >= minimumChunk else {
            result.emptyReason = .minChunkUnmet
            result.explanation = "largest free stretch is \(roomMinutes) min, below the \(minimumChunk) min minimum chunk"
            return result
        }

        let maxChunk = task.splittable
            ? max(minimumChunk, config.maxSessionMinutes)
            : remaining

        var used: [Interval] = []
        var guardCount = 0
        while remaining > 0 && guardCount < 64 {
            guard remaining >= minimumChunk else { break }
            guardCount += 1
            let available = IntervalOps.subtract(pool, used)
            var want = task.splittable ? min(remaining, maxChunk) : remaining
            if task.splittable {
                // Never leave a tail smaller than the minimum chunk: shorten this chunk instead.
                let tail = remaining - want
                if tail > 0 && tail < minimumChunk {
                    let adjusted = min(maxChunk, remaining - minimumChunk)
                    want = adjusted >= minimumChunk ? adjusted : min(remaining, maxChunk)
                }
            }
            guard let candidate = bestCandidate(
                task: task,
                earliest: earliest,
                latest: latest,
                ideal: ideal,
                pool: available,
                duration: want,
                aligner: aligner
            ) else {
                // A task that may not be split must fit in one piece.
                guard task.splittable else { break }
                let capacity = available.map { Int(($0.duration / 60).rounded(.down)) }.max() ?? 0
                var shrunk = min(want - 1, capacity)
                var found: Interval? = nil
                while shrunk >= minimumChunk {
                    if let smaller = bestCandidate(
                        task: task,
                        earliest: earliest,
                        latest: latest,
                        ideal: ideal,
                        pool: available,
                        duration: shrunk,
                        aligner: aligner
                    ) {
                        found = smaller
                        break
                    }
                        shrunk -= 1
                }
                guard let fallback = found else { break }
                used.append(fallback)
                result.intervals.append(fallback)
                result.assignedMinutes += fallback.minutes
                remaining -= fallback.minutes
                continue
            }
            used.append(candidate)
            result.intervals.append(candidate)
            result.assignedMinutes += candidate.minutes
            remaining -= candidate.minutes
            if !task.splittable { break }
        }

        result.shortfallMinutes = max(0, remaining)
        result.forcedAlignment = result.intervals.contains { aligner.floor($0.start) != $0.start }
        if result.shortfallMinutes > 0 {
            let totalRoom = IntervalOps.totalMinutes(IntervalOps.clamp(pool, to: Interval(start: earliest, end: latest)))
            if totalRoom < task.remainingMinutes {
                result.shortfallReason = .insufficientTotalTime
                result.explanation = "only \(totalRoom) min available inside the allowed window, \(task.remainingMinutes) min needed"
            } else if !task.splittable {
                result.shortfallReason = .noContiguousBlock
                result.explanation = "\(totalRoom) min free in total but no single contiguous \(task.remainingMinutes) min block, and the task may not be split"
            } else {
                result.shortfallReason = .minChunkUnmet
                result.explanation = "the current placement left no valid chunk of at least \(minimumChunk) min; a different placement may fit"
            }
            if result.intervals.isEmpty {
                result.emptyReason = result.shortfallReason
            }
        }
        return result
    }

    private func bestCandidate(
        task: PlanTask,
        earliest: Date,
        latest: Date,
        ideal: Date,
        pool: [Interval],
        duration: Int,
        aligner: GridAligner
    ) -> Interval? {
        var candidates: [Interval] = []
        let span = latest.timeIntervalSince(earliest)

        for segment in pool {
            let low = max(segment.start, earliest)
            let high = min(segment.end, latest)
            guard high > low else { continue }
            let roomMinutes = Int((high.timeIntervalSince(low) / 60).rounded(.down))
            guard roomMinutes >= duration else { continue }

            let lastStart = high.addingTimeInterval(-Double(duration) * 60)
            let target = min(max(low, ideal), lastStart)
            let anchors = [low, aligner.floor(target), target, lastStart]

            for anchor in anchors {
                var start = aligner.ceiling(anchor)
                var end = start.addingTimeInterval(Double(duration) * 60)
                if end > high {
                    start = aligner.floor(high.addingTimeInterval(-Double(duration) * 60))
                    end = start.addingTimeInterval(Double(duration) * 60)
                }
                guard start >= low, end <= high, end > start else { continue }
                let candidate = Interval(start: start, end: end)
                if !candidates.contains(candidate) { candidates.append(candidate) }
            }
        }

        // A valid exact fit takes precedence over cosmetic grid alignment.
        if candidates.isEmpty {
            for segment in pool {
                let low = max(segment.start, earliest)
                let high = min(segment.end, latest).addingTimeInterval(-Double(duration) * 60)
                guard low <= high else { continue }
                let start = min(max(low, ideal), high)
                candidates.append(Interval(start: start, end: start.addingTimeInterval(Double(duration) * 60)))
            }
        }
        guard !candidates.isEmpty else { return nil }

        let scored = candidates.map { candidate -> (Interval, Double) in
            let deviation = abs(candidate.start.timeIntervalSince(ideal)) / max(span, 1)
            let preferencePenalty = self.preferencePenalty(for: candidate.start, preference: task.preference)
            return (candidate, deviation + preferencePenalty)
        }

        let best = scored.min { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            if lhs.0.start != rhs.0.start { return lhs.0.start < rhs.0.start }
            return lhs.0.end < rhs.0.end
        }
        return best?.0
    }

    private func preferencePenalty(for start: Date, preference: TaskPreference) -> Double {
        guard preference != .any else { return 0 }
        let hour = math.calendar.component(.hour, from: start)
        switch preference {
        case .morning: return hour < 12 ? 0 : 0.35
        case .afternoon: return hour >= 12 ? 0 : 0.35
        case .any: return 0
        }
    }

    private func isMutuallyConcurrent(_ lhs: String, _ rhs: String, tasks: [PlanTask]) -> Bool {
        guard let left = tasks.first(where: { $0.id == lhs }),
              let right = tasks.first(where: { $0.id == rhs }) else { return false }
        return left.allowConcurrentWith.contains(rhs) && right.allowConcurrentWith.contains(lhs)
    }

    // MARK: - Ordering

    /// Dependency-aware ordering: a task is only considered once all of its
    /// dependencies have been considered, and among ready tasks the one with
    /// higher priority, then earlier deadline, then smaller id goes first.
    private func ordering(_ tasks: [PlanTask]) throws -> [PlanTask] {
        let known = Set(tasks.map { $0.id })
        var byID: [String: PlanTask] = [:]
        for task in tasks where byID[task.id] == nil { byID[task.id] = task }

        var indegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]
        for task in byID.values {
            indegree[task.id, default: 0] += 0
            for dependency in task.dependsOn where known.contains(dependency) {
                indegree[task.id, default: 0] += 1
                dependents[dependency, default: []].append(task.id)
            }
        }

        func sortKey(_ task: PlanTask) -> (Int, Date, String) {
            let deadlineKey: Date
            switch task.deadline {
            case .some(.instant(let date)): deadlineKey = date
            case .some(.date(let local)): deadlineKey = math.endOfDay(for: local) ?? .distantFuture
            case .none: deadlineKey = .distantFuture
            }
            return (task.priority, deadlineKey, task.id)
        }

        var ready = byID.values.filter { (indegree[$0.id] ?? 0) == 0 }
        var ordered: [PlanTask] = []
        while !ready.isEmpty {
            ready.sort { sortKey($0) < sortKey($1) }
            let next = ready.removeFirst()
            ordered.append(next)
            for dependent in (dependents[next.id] ?? []).sorted() {
                indegree[dependent, default: 0] -= 1
                if indegree[dependent] == 0, let task = byID[dependent] {
                    ready.append(task)
                }
            }
        }

        if ordered.count < byID.count {
            let placed = Set(ordered.map { $0.id })
            let remaining = byID.keys.filter { !placed.contains($0) }.sorted()
            throw SchedulerError.dependencyCycle(remaining)
        }
        return ordered
    }

    // MARK: - Explanations

    private func assumptions(range: Interval) -> [String] {
        var notes: [String] = []
        notes.append("time zone: \(math.identifier); range \(math.formatInstant(range.start)) → \(math.formatInstant(range.end))")
        let weekdays = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var windowNotes: [String] = []
        for entry in config.weeklyWindows.sorted(by: { $0.weekday < $1.weekday }) {
            let text = entry.windows.map { "\($0.start)-\($0.end)" }.joined(separator: ", ")
            windowNotes.append("\(weekdays[entry.weekday]): \(text.isEmpty ? "closed" : text)")
        }
        notes.append("working windows: " + windowNotes.joined(separator: "; "))
        notes.append("placement grid: \(config.granularityMinutes) min; ideal position in window: \(Int(config.targetPosition * 100))%")
        notes.append("safety buffer before deadlines: \(config.bufferWorkdays) working day(s) for priority ≥ 2 tasks")
        notes.append("events with unknown or tentative availability are treated as occupied; only availability 'free' is ignored")
        notes.append("deadline buffers count configured working days; holidays are handled as calendar occupancy")
        return notes
    }
}
