import AppleBridge
import Foundation
import MCP
import SchedulerCore
import SchedulerStore
import Testing
@testable import SchedulerTools

private actor MemoryWriter: ManagedAppleStore {
    var values: [String: ManagedItem] = [:]
    var writes = 0
    var rejectTarget = false

    func container(_ kind: ManagedItem.Kind, named name: String, bound: ManagedContainer?,
                   create: Bool) throws -> ManagedContainer? {
        if rejectTarget { throw EventKitError("目标集合无法验证") }
        return bound ?? (create ? ManagedContainer(calendarID: kind.rawValue, sourceID: "test") : nil)
    }

    func current(_ change: ScheduleChange, in container: ManagedContainer) -> ManagedItem? { values[change.item.id] }

    func apply(_ change: ScheduleChange, in container: ManagedContainer) {
        writes += 1
        values[change.item.id] = change.after
    }

    func reject() { rejectTarget = true }
}

private final class MutableReader: CalendarSource, @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [EventItem] = []

    func add(_ item: EventItem) { lock.withLock { blocks.append(item) } }
    func eventCalendars() -> [CalendarSummary] { [] }
    func reminderCalendars() -> [CalendarSummary] { [] }
    func events(from start: Date, to end: Date, calendarIDs: [String]?) -> [EventItem] {
        lock.withLock { blocks.filter { $0.start < end && start < $0.end } }
    }
    func reminders(includeCompleted: Bool, dueFrom: Date?, dueTo: Date?, listIDs: [String]?) async -> [ReminderItem] { [] }
}

@Suite("写回和恢复")
struct ManagedScheduleTests {
    private let event = ManagedItem(id: "owned-event", taskID: "task", kind: .event, title: "研究",
                                    start: Fixture.now.addingTimeInterval(7_200),
                                    end: Fixture.now.addingTimeInterval(10_800))
    private let reminder = ManagedItem(id: "owned-reminder", taskID: "task", kind: .reminder, title: "提醒",
                                       start: Fixture.now.addingTimeInterval(6_000))

    private func service(_ writer: MemoryWriter, reader: MutableReader = MutableReader(),
                         path: String = Fixture.temporaryStorePath()) -> ManagedScheduleService {
        ManagedScheduleService(path: path, reader: reader, writer: writer, now: { Fixture.now })
    }

    private func id(_ preview: Value) throws -> String {
        try #require(preview.objectValue?["plan_id"]?.stringValue)
    }

    @Test(arguments: [CreateElicitation.Result.Action.accept, .decline, .cancel, nil] as [CreateElicitation.Result.Action?])
    func commitRequiresClientConfirmation(action: CreateElicitation.Result.Action?) async throws {
        let writer = MemoryWriter()
        let reader = MutableReader()
        let service = CalendarToolService(source: reader, runtime: Fixture.runtime()) { path in
            self.service(writer, reader: reader, path: path)
        }
        let managed = try #require(service.managed)
        let id = try id(managed.draft([ScheduleChange(after: event)], zone: Fixture.timeZone))
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await MCPServerFactory.makeServer(service: service)
        try await server.start(transport: serverTransport)
        let client = Client(name: "confirmation-tests", version: "1",
                            capabilities: .init(elicitation: action.map { _ in .init(form: .init()) }))
        if let action {
            await client.withElicitationHandler { parameters in
                guard case .form(let form) = parameters else {
                    Issue.record("确认应在客户端内显示")
                    return .init(action: .cancel)
                }
                #expect(form.message.contains("AI 日程安排"))
                #expect(form.message.contains("研究"))
                #expect(form.message.contains("2026-03-03T10:00:00+08:00"))
                #expect(await writer.writes == 0)
                return .init(action: action)
            }
        }
        try await client.connect(transport: clientTransport)
        let arguments: [String: Value] = ["plan_id": .string(id), "confirmed": .bool(true)]
        let result = try await client.callTool(name: "commit_schedule", arguments: arguments)
        #expect(result.isError == (action == nil))
        #expect(await writer.writes == (action == .accept ? 1 : 0))
        let expected: ManagedJournal.State = action == .accept ? .applied : action == nil ? .preview : .declined
        #expect(try managed.journal(id).state == expected)
        if action == .accept {
            _ = try await client.callTool(name: "commit_schedule", arguments: arguments)
            #expect(await writer.writes == 1)
        }
        await client.disconnect()
        await server.stop()
    }

    @Test func createMoveCompleteAndUndo() async throws {
        let writer = MemoryWriter()
        let svc = service(writer)
        let creation = try id(svc.draft([ScheduleChange(after: event), ScheduleChange(after: reminder)], zone: Fixture.timeZone))
        let created = try await svc.commit(creation) { _ in true }
        #expect(created.state == .applied)
        _ = try await svc.commit(creation) { _ in false }
        #expect(await writer.writes == 2)

        var moved = event
        moved.start = moved.start.addingTimeInterval(3_600)
        moved.end = moved.end?.addingTimeInterval(3_600)
        var complete = reminder
        complete.completed = true
        let update = try id(svc.draft([ScheduleChange(before: event, after: moved),
                                       ScheduleChange(before: reminder, after: complete)], zone: Fixture.timeZone))
        let updated = try await svc.commit(update) { _ in true }
        #expect(updated.completedOperations == 2)
        #expect(try svc.items().contains(moved))
        #expect(try svc.items().contains(complete))
        let undo = try id(svc.undo(update, zone: Fixture.timeZone))
        let undone = try await svc.commit(undo) { _ in true }
        #expect(undone.state == .applied)
        #expect(try svc.items().contains(event))
        #expect(try svc.items().contains(reminder))
    }

    @Test func newExternalMeetingPreventsApprovedWrite() async throws {
        let writer = MemoryWriter()
        let reader = MutableReader()
        let svc = service(writer, reader: reader)
        let id = try id(svc.draft([ScheduleChange(after: event)], zone: Fixture.timeZone))
        let result = try await svc.commit(id) { _ in
            reader.add(EventItem(id: "meeting", title: "固定会议", start: event.start,
                                 end: try #require(event.end), notes: event.marker))
            return true
        }
        #expect(result.state == .needsReview)
        #expect(await writer.writes == 0)
    }

    @Test func rejectsInvalidTargetBeforeApproval() async throws {
        let writer = MemoryWriter()
        await writer.reject()
        let svc = service(writer)
        let id = try id(svc.draft([ScheduleChange(after: reminder)], zone: Fixture.timeZone))
        await #expect(throws: EventKitError.self) { try await svc.commit(id) { _ in true } }
        #expect(await writer.writes == 0)
    }

    @Test func reconcilesWriteAlreadySavedBeforeInterruption() async throws {
        let writer = MemoryWriter()
        let path = Fixture.temporaryStorePath()
        let svc = service(writer, path: path)
        let id = try id(svc.draft([ScheduleChange(after: reminder)], zone: Fixture.timeZone))
        let store = try PlanStore(path: path)
        let target = ManagedContainer(calendarID: "reminder", sourceID: "test")
        try store.put(target, in: "container", key: "reminder")
        var interrupted = try svc.journal(id)
        interrupted.state = .applying
        interrupted.inFlight = 0
        try store.saveJournal(interrupted)
        await writer.apply(ScheduleChange(after: reminder), in: target)
        let result = try await svc.commit(id) { _ in true }
        #expect(result.state == .applied)
        #expect(await writer.writes == 1)
        #expect(try svc.items() == [reminder])
    }

    @Test func localCompletionCanBeUndoneEvenWithoutCalendarChanges() async throws {
        let writer = MemoryWriter()
        let svc = service(writer)
        let completion = TaskCompletionChange(taskID: "historic-task", before: false, after: true)
        let done = try id(svc.draft([], zone: Fixture.timeZone, taskCompletion: completion))
        let approved = try await svc.commit(done) { _ in true }
        #expect(approved.state == .applied)
        #expect(try svc.isTaskComplete(completion.taskID))
        let undo = try id(svc.undo(done, zone: Fixture.timeZone))
        let undone = try await svc.commit(undo) { _ in true }
        #expect(undone.state == .applied)
        #expect(try !svc.isTaskComplete(completion.taskID))
        #expect(await writer.writes == 0)
    }

    @Test func refusesTimeBlocksPastTaskDeadline() async throws {
        let writer = MemoryWriter()
        let svc = service(writer)
        var late = event
        late.latestAllowed = event.start
        let id = try id(svc.draft([ScheduleChange(after: late)], zone: Fixture.timeZone))
        await #expect(throws: ToolInputError.self) { try await svc.commit(id) { _ in true } }
        #expect(await writer.writes == 0)
    }
}
