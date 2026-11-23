import AppleBridge
import Foundation
import MCP
import SchedulerCore
import Testing

@testable import SchedulerTools

func firstText(_ content: [Tool.Content]) -> String? {
    guard case let .text(text, _, _) = content.first else { return nil }
    return text
}

// MARK: - Fixtures

/// A calendar source with no EventKit behind it, so the tool surface can be tested
/// without touching the real calendar or asking for permissions.
struct FakeCalendarSource: CalendarSource {
    var eventLists: [CalendarSummary] = []
    var reminderLists: [CalendarSummary] = []
    var events: [EventItem] = []
    var reminders: [ReminderItem] = []
    /// Lets a test simulate a machine without calendar permission.
    var eventsError: EventKitError? = nil

    func eventCalendars() throws -> [CalendarSummary] { eventLists }
    func reminderCalendars() throws -> [CalendarSummary] { reminderLists }

    func events(from start: Date, to end: Date, calendarIDs: [String]?) throws -> [EventItem] {
        if let eventsError { throw eventsError }
        return events
            .filter { $0.start < end && start < $0.end }
            .filter { calendarIDs == nil || calendarIDs!.contains($0.calendarID) }
    }

    func reminders(
        includeCompleted: Bool,
        dueFrom: Date?,
        dueTo: Date?,
        listIDs: [String]?
    ) async throws -> [ReminderItem] {
        reminders.filter { includeCompleted || !$0.isCompleted }
    }
}

enum Fixture {
    static let timeZone = "Asia/Shanghai"

    /// Tuesday 2026-03-03 08:00 in Asia/Shanghai — a working day in the default config.
    static let now = date("2026-03-03T08:00:00+08:00")

    static func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    static func temporaryStorePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-scheduler-test-\(UUID().uuidString)")
            .appendingPathComponent("plans.sqlite")
            .path
    }

    static func runtime(storePath: String? = nil) -> ToolRuntime {
        ToolRuntime(
            timeZoneID: timeZone,
            storePath: storePath ?? temporaryStorePath(),
            now: { now }
        )
    }

    static func source() -> FakeCalendarSource {
        FakeCalendarSource(
            eventLists: [
                CalendarSummary(
                    id: "work", title: "工作", source: "iCloud", kind: "calendar",
                    allowsContentModifications: true, isImmutable: false
                )
            ],
            reminderLists: [
                CalendarSummary(
                    id: "todo", title: "待办", source: "iCloud", kind: "reminder",
                    allowsContentModifications: true, isImmutable: false
                )
            ],
            events: [
                EventItem(
                    id: "evt-1",
                    title: "组会",
                    start: date("2026-03-03T09:00:00+08:00"),
                    end: date("2026-03-03T10:00:00+08:00"),
                    calendarID: "work",
                    calendarTitle: "工作"
                )
            ],
            reminders: [
                ReminderItem(
                    id: "rem-1",
                    title: "交开题报告",
                    listID: "todo",
                    listTitle: "待办",
                    dueDate: date("2026-03-04T23:59:00+08:00"),
                    hasDueTime: true,
                    priority: 1
                )
            ]
        )
    }

    static func service(storePath: String? = nil) -> CalendarToolService {
        CalendarToolService(source: source(), runtime: runtime(storePath: storePath))
    }

    static func service(source: FakeCalendarSource, storePath: String? = nil) -> CalendarToolService {
        CalendarToolService(source: source, runtime: runtime(storePath: storePath))
    }
}

// MARK: - Catalog

@Suite("工具目录")
struct ToolCatalogTests {
    @Test("六个工具，全部标记为只读")
    func catalogIsReadOnly() {
        let tools = ToolCatalog.tools
        #expect(tools.count == 6)
        #expect(Set(tools.map(\.name)) == [
            "list_calendars", "list_events", "list_reminders",
            "find_free_slots", "plan_tasks", "preview_schedule",
        ])
        for tool in tools {
            #expect(tool.annotations.readOnlyHint == true, "\(tool.name) 必须是只读的")
            #expect(tool.annotations.openWorldHint == false)
            #expect(tool.description?.isEmpty == false)
            #expect(tool.inputSchema.objectValue?["type"]?.stringValue == "object")
        }
    }

    @Test("plan_tasks 的 schema 要求 tasks 为数组")
    func planSchemaRequiresTasks() throws {
        let tool = try #require(ToolCatalog.tools.first { $0.name == "plan_tasks" })
        let schema = try #require(tool.inputSchema.objectValue)
        #expect(schema["required"]?.arrayValue?.compactMap(\.stringValue).contains("tasks") == true)
    }
}

// MARK: - Reading tools

@Suite("读取类工具")
struct ReadToolTests {
    @Test("list_calendars 同时返回日历与提醒清单")
    func listsCalendars() async throws {
        let value = try await Fixture.service().call("list_calendars", [:])
        let object = try #require(value.objectValue)
        #expect(object["count"]?.intValue == 2)
        let kinds = object["calendars"]?.arrayValue?.compactMap { $0.objectValue?["kind"]?.stringValue }
        #expect(kinds == ["event", "reminder_list"])
    }

    @Test("list_events 返回区间内事件并标记占用")
    func listsEvents() async throws {
        let value = try await Fixture.service().call("list_events", [
            "start": .string("2026-03-03"),
            "end": .string("2026-03-04"),
        ])
        let object = try #require(value.objectValue)
        #expect(object["count"]?.intValue == 1)
        let event = try #require(object["events"]?.arrayValue?.first?.objectValue)
        #expect(event["title"]?.stringValue == "组会")
        #expect(event["blocks_scheduling"]?.boolValue == true)
        #expect(event["start_time"]?.stringValue == "09:00")
    }

    @Test("list_reminders 带出截止时间")
    func listsReminders() async throws {
        let value = try await Fixture.service().call("list_reminders", [:])
        let object = try #require(value.objectValue)
        #expect(object["count"]?.intValue == 1)
        let reminder = try #require(object["reminders"]?.arrayValue?.first?.objectValue)
        #expect(reminder["title"]?.stringValue == "交开题报告")
        #expect(reminder["due_date"]?.stringValue == "2026-03-04")
        #expect(reminder["scheduler_priority"]?.intValue == 1)
    }

    @Test("find_free_slots 跳过会议占用的时段")
    func findsFreeSlots() async throws {
        let value = try await Fixture.service().call("find_free_slots", [
            "start": .string("2026-03-03"),
            "end": .string("2026-03-03"),
            "minimum_minutes": .int(60),
        ])
        let object = try #require(value.objectValue)
        let slots = object["free_slots"]?.arrayValue?.compactMap(\.objectValue) ?? []
        #expect(!slots.isEmpty)
        // 9:00–10:00 被组会占用，第一个空档必须从 10:00 开始。
        // 纯日期作 end 表示“到该日结束”，所以区间正好是 3 月 3 日这一天。
        #expect(object["count"]?.intValue == 2)
        #expect(object["total_free_minutes"]?.intValue == 420)
        #expect(slots.first?["start_time"]?.stringValue == "10:00")
        #expect(slots.last?["start_time"]?.stringValue == "13:00")
        let excluded = object["excluded"]?.arrayValue?.compactMap(\.objectValue) ?? []
        #expect(excluded.first?["title"]?.stringValue == "组会")
        #expect(excluded.first?["reason"]?.stringValue == "busy")
    }

    @Test("周末默认没有工作窗口")
    func weekendHasNoWindows() async throws {
        let value = try await Fixture.service().call("find_free_slots", [
            "start": .string("2026-03-07"),
            "end": .string("2026-03-07"),
            "minimum_minutes": .int(30),
        ])
        let object = try #require(value.objectValue)
        #expect(object["count"]?.intValue == 0)
        #expect(object["total_free_minutes"]?.intValue == 0)
    }
}

// MARK: - Planning tools

@Suite("排程与预览")
struct PlanningToolTests {
    @Test("plan_tasks 排出时间块并落盘，preview 能读回同一份计划")
    func plansAndPreviews() async throws {
        let storePath = Fixture.temporaryStorePath()
        let service = Fixture.service(storePath: storePath)

        let planned = try await service.call("plan_tasks", [
            "range_start": .string("2026-03-03"),
            "range_end": .string("2026-03-05"),
            "tasks": .array([
                .object([
                    "title": .string("写开题报告"),
                    "estimated_minutes": .int(60),
                    "priority": .int(2),
                ])
            ]),
        ])
        let plan = try #require(planned.objectValue)
        let planID = try #require(plan["plan_id"]?.stringValue)
        #expect(plan["saved"]?.boolValue == true)

        let assignments = plan["assignments"]?.arrayValue?.compactMap(\.objectValue) ?? []
        #expect(assignments.count == 1)
        let block = try #require(assignments.first)
        #expect(block["title"]?.stringValue == "写开题报告")
        #expect(block["minutes"]?.intValue == 60)
        #expect(block["split_count"]?.intValue == 1)
        // 不能压在 09:00–10:00 的组会上。
        let day = try #require(block["date"]?.stringValue)
        let startTime = try #require(block["start_time"]?.stringValue)
        if day == "2026-03-03" {
            #expect(startTime >= "10:00")
        }
        #expect(["2026-03-03", "2026-03-04"].contains(day))
        #expect(plan["statistics"]?.objectValue?["scheduled_task_count"]?.intValue == 1)

        let previewed = try await service.call("preview_schedule", ["plan_id": .string(planID)])
        let preview = try #require(previewed.objectValue)
        #expect(preview["plan_id"]?.stringValue == planID)
        #expect(preview["summary"]?.objectValue?["blocks"]?.intValue == 1)
        #expect(preview["conflicts"]?.arrayValue?.isEmpty == true)

        let authorization = try #require(preview["authorization"]?.objectValue)
        #expect(authorization["write_performed"]?.boolValue == false)
        #expect(authorization["requires_human_confirmation"]?.boolValue == false)
        #expect(authorization["commit_available"]?.boolValue == false)

        let operations = try #require(preview["operations"]?.arrayValue?.first?.objectValue)
        #expect(operations["op"]?.stringValue == "create_time_block")
        #expect(operations["target_calendar"]?.stringValue == "AI 日程安排")
    }

    @Test("排不下时给出原因而不是静默丢弃")
    func reportsUnscheduled() async throws {
        let service = Fixture.service()
        let planned = try await service.call("plan_tasks", [
            "range_start": .string("2026-03-03"),
            "range_end": .string("2026-03-04"),
            "tasks": .array([
                .object([
                    "title": .string("写一天"),
                    "estimated_minutes": .int(600),
                    "splittable": .bool(false),
                ])
            ]),
        ])
        let plan = try #require(planned.objectValue)
        let unscheduled = try #require(plan["unscheduled"]?.arrayValue?.first?.objectValue)
        #expect(unscheduled["task_id"]?.stringValue == "task-1")
        #expect(["no_free_interval", "insufficient_total_time", "no_contiguous_block"]
            .contains(try #require(unscheduled["reason"]?.stringValue)))
        #expect(plan["statistics"]?.objectValue?["allocated_minutes"]?.intValue == 0)
    }

    @Test("preview 的 use_calendar=false 会明确说明冲突未检查")
    func previewSkipsCalendarOnRequest() async throws {
        let service = Fixture.service()
        let planned = try await service.call("plan_tasks", [
            "range_start": .string("2026-03-03"),
            "range_end": .string("2026-03-04"),
            "tasks": .array([
                .object(["title": .string("写开题报告"), "estimated_minutes": .int(60)])
            ]),
        ])
        let planID = try #require(planned.objectValue?["plan_id"]?.stringValue)

        let previewed = try await service.call("preview_schedule", [
            "plan_id": .string(planID),
            "use_calendar": .bool(false),
        ])
        let preview = try #require(previewed.objectValue)
        #expect(preview["conflict_check"]?.stringValue == "skipped_by_request")
        #expect(preview["conflicts"]?.arrayValue?.isEmpty == true)
        let warnings = preview["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(warnings.contains { $0.contains("冲突检查未执行") })
    }

    @Test("没有日历权限时 preview 降级而不是失败")
    func previewDegradesWithoutPermission() async throws {
        var source = Fixture.source()
        source.eventsError = EventKitError("calendar access is not granted (state: denied)")
        let service = Fixture.service(source: source)
        let planned = try await service.call("plan_tasks", [
            "range_start": .string("2026-03-03"),
            "range_end": .string("2026-03-04"),
            "use_calendar": .bool(false),
            "busy_blocks": .array([
                .object([
                    "title": .string("组会"),
                    "start": .string("2026-03-03T09:00"),
                    "end": .string("2026-03-03T10:00"),
                ])
            ]),
            "tasks": .array([
                .object(["title": .string("写开题报告"), "estimated_minutes": .int(60)])
            ]),
        ])
        let planID = try #require(planned.objectValue?["plan_id"]?.stringValue)

        let previewed = try await service.call("preview_schedule", ["plan_id": .string(planID)])
        let preview = try #require(previewed.objectValue)
        #expect(preview["conflict_check"]?.stringValue == "skipped_permission_denied")
        #expect(preview["conflicts"]?.arrayValue?.isEmpty == true)
        let warnings = preview["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(warnings.contains { $0.contains("冲突检查已跳过") })
    }

    @Test("preview 未知 plan_id 直接报错")
    func previewRejectsUnknownPlan() async throws {
        await #expect(throws: (any Error).self) {
            try await Fixture.service().call("preview_schedule", ["plan_id": .string("does-not-exist")])
        }
    }
}

// MARK: - Input validation

@Suite("参数校验")
struct ValidationTests {
    @Test("不指定范围时从当前时间读取七天")
    func defaultsToSevenDays() async throws {
        let result = try await Fixture.service().call("list_events", [:])
        let range = try #require(result.objectValue?["range"]?.objectValue)
        #expect(range["start"]?.stringValue == "2026-03-03T08:00:00+08:00")
        #expect(range["end"]?.stringValue == "2026-03-10T08:00:00+08:00")
    }

    @Test("提醒可翻页，仅日期的提醒在转换时区时保留日期")
    func pagesRemindersAndPreservesDateOnlyValues() async throws {
        var source = Fixture.source()
        source.reminders.append(
            ReminderItem(
                id: "rem-2", title: "全天待办", notes: "不应默认返回",
                dueDate: Fixture.date("2026-03-05T00:00:00+08:00"), localDueDate: "2026-03-05"
            )
        )
        let service = Fixture.service(source: source)
        let first = try await service.call("list_reminders", ["limit": .int(1)])
        #expect(first.objectValue?["next_offset"]?.intValue == 1)
        let second = try await service.call("list_reminders", [
            "offset": .int(1), "time_zone": .string("America/New_York"),
        ])
        let item = try #require(second.objectValue?["reminders"]?.arrayValue?.first?.objectValue)
        #expect(item["due_date"]?.stringValue == "2026-03-05")
        #expect(item["due_at"] == nil)
        #expect(item["notes"] == nil)
        #expect(second.objectValue?["truncated"]?.boolValue == false)
    }

    @Test("本次开放周一窗口时，仍扣除明确参加活动的占用")
    func respectsCustomWindowsAndBusyTimes() async throws {
        let result = try await Fixture.service().call("find_free_slots", [
            "start": .string("2026-03-09"),
            "end": .string("2026-03-09"),
            "use_calendar": .bool(false),
            "working_windows": .array([.object([
                "weekday": .int(2), "start": .string("14:00"), "end": .string("18:00"),
            ])]),
            "busy_blocks": .array([.object([
                "title": .string("课程"), "start": .string("2026-03-09T14:45"),
                "end": .string("2026-03-09T16:25"),
            ])]),
        ])
        let slots = try #require(result.objectValue?["free_slots"]?.arrayValue)
        #expect(slots.compactMap { $0.objectValue?["start_time"]?.stringValue } == ["14:00", "16:25"])
        #expect(result.objectValue?["calendar_checked"]?.boolValue == false)
    }

    @Test("无效日期与超大浮点整数不会被接受")
    func rejectsInvalidTaskDatesAndNumbers() async throws {
        let service = Fixture.service()
        await #expect(throws: ToolInputError.self) {
            try await service.call("plan_tasks", [
                "tasks": .array([.object(["title": .string("研究"), "estimated_minutes": .int(60),
                                          "deadline": .string("2026-02-31")])]),
            ])
        }
        await #expect(throws: ToolInputError.self) {
            try await service.call("plan_tasks", [
                "tasks": .array([.object(["title": .string("研究"), "estimated_minutes": .double(1e100)])]),
            ])
        }
    }

    @Test("结束早于开始时拒绝")
    func rejectsBackwardsRange() async throws {
        await #expect(throws: ToolInputError.self) {
            try await Fixture.service().call("find_free_slots", [
                "start": .string("2026-03-05"),
                "end": .string("2026-03-03"),
            ])
        }
    }

    @Test("非法时区被拒绝")
    func rejectsBadTimeZone() async throws {
        await #expect(throws: ToolInputError.self) {
            try await Fixture.service().call("find_free_slots", [
                "start": .string("2026-03-03"),
                "end": .string("2026-03-03"),
                "time_zone": .string("Mars/Olympus"),
            ])
        }
    }

    @Test("未知工具返回错误")
    func rejectsUnknownTool() async throws {
        await #expect(throws: ToolInputError.self) {
            try await Fixture.service().call("delete_everything", [:])
        }
    }
}

// MARK: - Protocol level

@Suite("MCP 协议层")
struct ProtocolTests {
    @Test("客户端能看到六个工具并成功调用")
    func servesToolsOverMCP() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await MCPServerFactory.makeServer(service: Fixture.service())
        try await server.start(transport: serverTransport)

        let client = Client(name: "codex-scheduler-tests", version: "0.1.0")
        try await client.connect(transport: clientTransport)

        let listed = try await client.listTools()
        #expect(listed.tools.count == 6)
        #expect(listed.tools.allSatisfy { $0.annotations.readOnlyHint == true })

        let (content, isError) = try await client.callTool(name: "list_calendars", arguments: [:])
        #expect(isError == false)
        let text = try #require(firstText(content))
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(payload?["count"] as? Int == 2)

        await client.disconnect()
        await server.stop()
    }

    @Test("工具失败时返回 isError 与结构化错误体")
    func reportsToolErrors() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await MCPServerFactory.makeServer(service: Fixture.service())
        try await server.start(transport: serverTransport)

        let client = Client(name: "codex-scheduler-tests", version: "0.1.0")
        try await client.connect(transport: clientTransport)

        let (content, isError) = try await client.callTool(name: "nope", arguments: [:])
        #expect(isError == true)
        let text = try #require(firstText(content))
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(payload?["tool"] as? String == "nope")
        #expect(payload?["write_performed"] as? Bool == false)
        #expect((payload?["error"] as? String)?.contains("unknown tool") == true)

        await client.disconnect()
        await server.stop()
    }
}
