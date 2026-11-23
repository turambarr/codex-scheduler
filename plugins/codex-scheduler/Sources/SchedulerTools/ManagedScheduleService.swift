import AppleBridge
import Foundation
import MCP
import SchedulerCore
import SchedulerStore

public struct ManagedScheduleService: Sendable {
    private let path: String
    private let reader: any CalendarSource
    private let writer: any ManagedAppleStore
    private let now: @Sendable () -> Date
    private let testSuffix: String?

    public init(path: String, reader: any CalendarSource, writer: any ManagedAppleStore,
                now: @escaping @Sendable () -> Date = { Date() },
                testSuffix: String? = nil) {
        self.path = path
        self.reader = reader
        self.writer = writer
        self.now = now
        self.testSuffix = testSuffix
    }

    public func journal(_ id: String) throws -> ManagedJournal {
        guard let journal = try PlanStore(path: path).managedValues(ManagedJournal.self, in: "journal", key: id).first else {
            throw ToolInputError("未找到变更预览，请先生成预览")
        }
        return journal
    }

    public func reservePlan(_ plan: SchedulePlan, tasks: [PlanTask], reminders: [ManagedItem]) async throws -> Value {
        let store = try PlanStore(path: path)
        return try await store.withWriteLock {
            if let existing = try store.managedValues(ManagedJournal.self, in: "journal", key: plan.planID).first {
                return try presentation(existing)
            }
            let taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            let math = try CalendarMath(timeZoneIdentifier: plan.timeZoneID)
            let events = plan.assignments.enumerated().map { index, block in
                let task = taskMap[block.taskID]
                return ManagedItem(id: "\(plan.planID)-\(index)",
                            taskID: "\(plan.planID):\(block.taskID)", kind: .event,
                            title: task?.title ?? block.taskID,
                            start: seconds(block.interval.start), end: seconds(block.interval.end),
                            earliestAllowed: task?.earliestStart, latestAllowed: task?.deadline.flatMap(math.deadlineInstant))
            }
            let pairs = tasks.flatMap { task in
                task.allowConcurrentWith.compactMap { partner -> [String]? in
                    guard task.id < partner, tasks.first(where: { $0.id == partner })?.allowConcurrentWith.contains(task.id) == true else { return nil }
                    return ["\(plan.planID):\(task.id)", "\(plan.planID):\(partner)"]
                }
            }
            let draft = ManagedDraft(id: plan.planID, timeZoneID: plan.timeZoneID, created: now(),
                                     changes: (events + reminders).map { ScheduleChange(after: $0) }, concurrentPairs: pairs)
            let entry = ManagedJournal(draft: draft)
            try store.saveJournal(entry)
            return try presentation(entry)
        }
    }

    public func draft(_ changes: [ScheduleChange], zone: String, taskCompletion: TaskCompletionChange? = nil,
                      concurrentPairs: [[String]] = []) throws -> Value {
        guard !changes.isEmpty || taskCompletion != nil else { throw ToolInputError("没有可变更的事项") }
        let entry = ManagedJournal(draft: ManagedDraft(timeZoneID: zone, created: now(), changes: changes,
                                                       concurrentPairs: concurrentPairs, taskCompletion: taskCompletion))
        try PlanStore(path: path).saveJournal(entry)
        return try presentation(entry)
    }

    public func items() throws -> [ManagedItem] {
        try PlanStore(path: path).managedValues(ManagedItemRecord.self, in: "item").compactMap(\.current)
    }

    public func isTaskComplete(_ id: String) throws -> Bool {
        try PlanStore(path: path).managedValues(Bool.self, in: "completion", key: id).first ?? false
    }

    public func commit(_ id: String, confirm: @Sendable (String) async throws -> Bool) async throws -> ManagedJournal {
        let prepared = try await prepareReview(id)
        guard canConfirm(prepared.state) else { return prepared }
        guard try await confirm(confirmationText(prepared)) else {
            return try await decline(prepared.draft)
        }
        try Task.checkCancellation()
        return try await applyAfterConfirmation(prepared.draft)
    }

    private func canConfirm(_ state: ManagedJournal.State) -> Bool {
        [.preview, .awaitingConfirmation, .applying].contains(state)
    }

    private func prepareReview(_ id: String) async throws -> ManagedJournal {
        let store = try PlanStore(path: path)
        return try await store.withWriteLock {
            let record = try journal(id)
            guard canConfirm(record.state) else { return record }
            guard record.draft.expires > now() else { throw ToolInputError("预览已过期，请重新规划") }
            guard !record.draft.changes.isEmpty || record.draft.taskCompletion != nil else {
                throw ToolInputError("这份预览没有可提交的变更")
            }
            if record.state != .applying {
                try await validate(record.draft, store: store, from: 0)
            }
            return record
        }
    }

    private func decline(_ expected: ManagedDraft) async throws -> ManagedJournal {
        let store = try PlanStore(path: path)
        return try await store.withWriteLock {
            var record = try journal(expected.id)
            guard record.draft == expected, [.preview, .awaitingConfirmation].contains(record.state) else { return record }
            record.state = .declined
            try store.saveJournal(record)
            return record
        }
    }

    private func applyAfterConfirmation(_ expected: ManagedDraft) async throws -> ManagedJournal {
        let store = try PlanStore(path: path)
        return try await store.withWriteLock {
            var record = try journal(expected.id)
            guard record.draft == expected else { throw ToolInputError("预览内容已变化，请重新确认") }
            guard canConfirm(record.state) else { return record }
            guard expected.expires > now() else { throw ToolInputError("此预览不能提交，请重新规划") }
            do {
                if let index = record.inFlight {
                    let change = expected.changes[index]
                    guard let bound = try boundContainer(change.item.kind, store: store),
                          let desired = change.after, try await writer.current(change, in: bound) == desired else {
                        throw ToolInputError("上一次写入结果无法确定，请核对原事项后再处理")
                    }
                    try finishOperation(&record, change: change, index: index, store: store)
                }
                try await validate(expected, store: store, from: record.completedOperations)
                record.state = .applying
                try store.saveJournal(record)
                for index in record.completedOperations..<expected.changes.count {
                    let change = expected.changes[index]
                    let kind = change.item.kind
                    guard let container = try await writer.container(kind, named: name(kind),
                                                                     bound: boundContainer(kind, store: store), create: true) else {
                        throw ToolInputError("无法验证专用日历或提醒清单")
                    }
                    try store.put(container, in: "container", key: kind.rawValue)
                    // Recheck external occupancy immediately before each event mutation.
                    try checkConflicts(change, draft: expected, calendarID: boundContainer(.event, store: store)?.calendarID)
                    record.inFlight = index
                    try store.saveJournal(record)
                    try await writer.apply(change, in: container)
                    guard try await writer.current(change, in: container) == change.after else {
                        throw ToolInputError("写入后未能核对结果")
                    }
                    try finishOperation(&record, change: change, index: index, store: store)
                }
                record.state = .applied
                try store.saveJournal(record)
            } catch {
                record.state = .needsReview
                record.message = String(describing: error)
                try store.saveJournal(record)
            }
            return record
        }
    }

    private func finishOperation(_ record: inout ManagedJournal, change: ScheduleChange,
                                 index: Int, store: PlanStore) throws {
        record.completedOperations = index + 1
        record.inFlight = nil
        try store.saveJournal(record, changedItem: ManagedItemRecord(id: change.item.id, current: change.after))
    }

    public func undo(_ id: String, zone: String) throws -> Value {
        let previous = try journal(id)
        guard previous.completedOperations > 0 || (previous.draft.taskCompletion != nil && previous.state == .applied),
              previous.inFlight == nil,
              previous.state == .applied || previous.state == .needsReview else {
            throw ToolInputError("当前记录没有可安全撤销的已核对变更")
        }
        let changes = previous.draft.changes.prefix(previous.completedOperations).reversed().map {
            ScheduleChange(before: $0.after, after: $0.before)
        }
        let completion = previous.state == .applied ? previous.draft.taskCompletion.map {
            TaskCompletionChange(taskID: $0.taskID, before: $0.after, after: $0.before)
        } : nil
        return try draft(changes, zone: zone, taskCompletion: completion, concurrentPairs: previous.draft.concurrentPairs)
    }

    private func boundContainer(_ kind: ManagedItem.Kind, store: PlanStore) throws -> ManagedContainer? {
        try store.managedValues(ManagedContainer.self, in: "container", key: kind.rawValue).first
    }

    private func validate(_ draft: ManagedDraft, store: PlanStore, from offset: Int) async throws {
        let remaining = Array(draft.changes.dropFirst(offset))
        if let task = draft.taskCompletion, try isTaskComplete(task.taskID) != task.before {
            throw ToolInputError("任务的完成状态已变化，请重新预览")
        }
        let calendarID = try boundContainer(.event, store: store)?.calendarID
        guard Set(remaining.map { $0.item.id }).count == remaining.count else { throw ToolInputError("事项重复") }
        for change in remaining {
            let kind = change.item.kind
            let current = try store.managedValues(ManagedItemRecord.self, in: "item", key: change.item.id).first?.current
            guard current == change.before else { throw ToolInputError("事项已被其他变更更新，请重新预览") }
            if kind == .event, change.item.start <= now() || (change.before?.start ?? .distantFuture) <= now() {
                throw ToolInputError("已开始或过去的时间块不能修改")
            }
            if let event = change.after, kind == .event {
                guard let end = event.end, event.start < end,
                      event.earliestAllowed.map({ event.start >= $0 }) ?? true,
                      event.latestAllowed.map({ end <= $0 }) ?? true else {
                    throw ToolInputError("时间块已超出任务的可安排时间或截止期限")
                }
            }
            if kind == .reminder, change.before == nil, change.item.start <= now() {
                throw ToolInputError("新提醒的时间已过，请重新预览")
            }
            if let container = try await writer.container(kind, named: name(kind), bound: boundContainer(kind, store: store), create: false) {
                guard try await writer.current(change, in: container) == change.before else {
                    throw ToolInputError("发现 Apple 事项已被手动修改，请重新预览")
                }
            } else if change.before != nil {
                throw ToolInputError("找不到原有事项的专用集合")
            }
            try checkConflicts(change, draft: draft, calendarID: calendarID)
        }
        let events = remaining.compactMap(\.after).filter { $0.kind == .event }
        for (index, left) in events.enumerated() {
            for right in events.dropFirst(index + 1) where left.start < right.end! && right.start < left.end! {
                guard allowsOverlap(left.taskID, right.taskID, draft: draft) else {
                    throw ToolInputError("预览内有两个未经允许并行的时间块重叠")
                }
            }
        }
    }

    private func checkConflicts(_ change: ScheduleChange, draft: ManagedDraft, calendarID: String?) throws {
        guard let after = change.after, after.kind == .event, let end = after.end, after.start < end else { return }
        let events = try reader.events(from: after.start, to: end, calendarIDs: nil)
        for event in events where event.availability != .free && event.start < end && after.start < event.end {
            if let before = change.before, event.calendarID == calendarID, event.notes == before.marker,
               event.start == before.start, event.end == before.end { continue }
            if draft.changes.contains(where: { other in
                guard let planned = other.after, event.calendarID == calendarID, event.notes == planned.marker,
                      event.start == planned.start, event.end == planned.end else { return false }
                return allowsOverlap(after.taskID, planned.taskID, draft: draft)
            }) { continue }
            throw ToolInputError("预览时段出现日历冲突，请重新规划")
        }
    }

    private func allowsOverlap(_ a: String, _ b: String, draft: ManagedDraft) -> Bool {
        draft.concurrentPairs.contains([a, b]) || draft.concurrentPairs.contains([b, a])
    }

    public func name(_ kind: ManagedItem.Kind) -> String {
        let base = kind == .event ? "AI 日程安排" : "AI 日程提醒"
        return testSuffix.map { "\(base) 测试 \($0)" } ?? base
    }

    private func confirmationText(_ record: ManagedJournal) throws -> String {
        let math = try CalendarMath(timeZoneIdentifier: record.draft.timeZoneID)
        func line(_ item: ManagedItem) -> String {
            let title = item.title.split(whereSeparator: \.isNewline).joined(separator: " ")
            let end = item.end.map { " 至 " + math.formatInstant($0) } ?? ""
            return "「\(title)」\(math.formatInstant(item.start))\(end)\(item.completed ? "（已完成）" : "")"
        }
        var lines = ["确认保存以下变更（\(math.identifier)）？"]
        if record.completedOperations > 0 {
            lines.append("已保存 \(record.completedOperations) 项。")
        }
        for change in record.draft.changes.dropFirst(record.completedOperations) {
            let action = change.action == "create" ? "新增" : change.action == "remove" ? "移除" : "修改"
            lines.append("\(action) · \(name(change.item.kind))")
            if let before = change.before { lines.append("原安排 \(line(before))") }
            if let after = change.after { lines.append("新安排 \(line(after))") }
        }
        if let completion = record.draft.taskCompletion {
            lines.append(completion.after ? "将关联任务标记为完成" : "恢复关联任务为未完成")
        }
        return lines.joined(separator: "\n")
    }

    public func presentation(_ record: ManagedJournal) throws -> Value {
        let math = try CalendarMath(timeZoneIdentifier: record.draft.timeZoneID)
        return .object([
            "plan_id": .string(record.draft.id),
            "time_zone": .string(math.identifier),
            "status": .string(record.state.rawValue),
            "expires_at": .string(math.formatInstant(record.draft.expires)),
            "completed_operations": .int(record.completedOperations),
            "task_completion": record.draft.taskCompletion.map {
                .object(["task_id": .string($0.taskID), "before": .bool($0.before), "after": .bool($0.after)])
            } ?? .null,
            "write_performed": .bool(record.completedOperations > 0),
            "write_outcome_uncertain": .bool(record.inFlight != nil),
            "requires_chat_confirmation": .bool(canConfirm(record.state)),
            "operations": .array(record.draft.changes.map { change in
                .object([
                    "action": .string(change.action),
                    "target": .string(name(change.item.kind)),
                    "before": change.before.map { itemValue($0, math: math) } ?? .null,
                    "after": change.after.map { itemValue($0, math: math) } ?? .null,
                ])
            }),
            "message": record.message.map(Value.string) ?? .null,
        ])
    }

    public func itemValue(_ value: ManagedItem, math: CalendarMath) -> Value {
        .object([
            "item_id": .string(value.id), "task_id": .string(value.taskID),
            "kind": .string(value.kind.rawValue), "title": .string(value.title),
            "start": .string(math.formatInstant(value.start)),
            "end": value.end.map { .string(math.formatInstant($0)) } ?? .null,
            "completed": .bool(value.completed),
        ])
    }

    public func seconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.up))
    }
}
