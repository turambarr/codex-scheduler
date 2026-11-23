import AppleBridge
import Foundation
import MCP
import SchedulerCore
import SchedulerStore
import SchedulerTools

struct CLIOptions {
    var timeZoneID: String = TimeZone.current.identifier
    var storePath: String = ToolRuntime.defaultStorePath
}

enum CLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

enum CLI {
    static let usage = """
    codex-scheduler \(ToolVersion.current) — 本地排程 MCP 服务

    用法：
      codex-scheduler mcp                    以 stdio 方式运行 MCP 服务（Codex 调用）
      codex-scheduler authorize              请求日历与提醒事项权限（首次使用先跑这个）
      codex-scheduler doctor                 检查权限、存储和工具列表
      codex-scheduler tools                  打印工具目录（JSON）
      codex-scheduler preview <plan_id>      打印已保存计划的变更预览
      codex-scheduler verify-writes          以独立测试集合验证写入

    通用选项：
      --time-zone <IANA>   默认本机时区
      --store <path>       计划存储位置，默认 ~/Library/Application Support/CodexScheduler/plans.sqlite

    变更只写入专用集合，并需要在 Codex 对话中确认。
    """

    static func run(_ argv: [String]) async -> Int32 {
        var arguments = argv
        var command: String?
        var positionals: [String] = []

        if let first = arguments.first, !first.hasPrefix("-") {
            command = first
            arguments.removeFirst()
        }

        var options = CLIOptions()
        if let value = ProcessInfo.processInfo.environment["CODEX_SCHEDULER_TIME_ZONE"],
           !value.trimmingCharacters(in: .whitespaces).isEmpty {
            options.timeZoneID = value
        }

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--time-zone":
                guard index + 1 < arguments.count else { return fail("--time-zone 需要一个值") }
                options.timeZoneID = arguments[index + 1]
                index += 2
            case "--store":
                guard index + 1 < arguments.count else { return fail("--store 需要一个值") }
                options.storePath = arguments[index + 1]
                index += 2
            case "--help", "-h":
                print(usage)
                return 0
            case "--version":
                print(ToolVersion.current)
                return 0
            default:
                positionals.append(arguments[index])
                index += 1
            }
        }

        switch command {
        case nil, "mcp":
            return await runMCPServer(options)
        case "doctor":
            return await runDoctor(options)
        case "tools":
            return runTools()
        case "verify-writes":
            return await verifyWrites(options)
        case "preview":
            guard let planID = positionals.first, !planID.isEmpty else {
                return fail("用法：codex-scheduler preview <plan_id>")
            }
            return await runPreview(planID, options)
        case "help":
            print(usage)
            return 0
        default:
            return fail("未知命令：\(command ?? "")\n\n\(usage)")
        }
    }

    // MARK: - Commands

    private static func runMCPServer(_ options: CLIOptions) async -> Int32 {
        do {
            let bridge = try EventKitBridge(timeZoneIdentifier: options.timeZoneID)
            let service = try makeService(bridge: bridge, options: options)
            let server = await MCPServerFactory.makeServer(service: service)
            log("codex-scheduler \(ToolVersion.current) 已启动（stdio）")
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
            return 0
        } catch {
            fail("MCP 服务启动失败：\(error)")
            return 1
        }
    }

    private static func runDoctor(_ options: CLIOptions) async -> Int32 {
        print("Codex Scheduler \(ToolVersion.current)")
        print("时区：\(options.timeZoneID)")

        let report = EventKitBridge.permissionReport()
        printReport(report)

        let storePath = StoreLocation.resolve(preferred: options.storePath)
        var ready = report.isFullyGranted
        do {
            let store = try PlanStore(path: storePath)
            let hint = storePath == options.storePath ? "" : "（默认位置不可写，已回退）"
            print("计划存储：\(storePath)\(hint)（已保存 \(try store.count()) 份）")
        } catch {
            print("计划存储：不可用 — \(error)")
            ready = false
        }

        do {
            let math = try CalendarMath(timeZoneIdentifier: options.timeZoneID)
            let bridge = try EventKitBridge(timeZoneIdentifier: options.timeZoneID)
            if report.canReadCalendar {
                let start = Date()
                let end = math.calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(604_800)
                let calendars = try bridge.eventCalendars()
                let events = try bridge.events(from: start, to: end)
                print("事件日历：\(calendars.count) 个，未来七天事件：\(events.count) 项")
            }
            if report.canReadReminders {
                let lists = try bridge.reminderCalendars()
                let openItems = try await bridge.reminders()
                print("提醒事项清单：\(lists.count) 个，未完成提醒：\(openItems.count) 项")
            }
        } catch {
            print("读取诊断未通过：\(error)")
            ready = false
        }

        let tools = ToolCatalog.tools + ToolCatalog.managedTools
        print("工具（\(tools.count)）：\(tools.map(\.name).joined(separator: ", "))")
        print("写入范围：专用日历和提醒清单。提交需要在 Codex 对话中确认。")

        if !report.isFullyGranted {
            print("结论：权限不完整。请在解锁的桌面上通过 open 命令启动应用授权，见 README。")
            return 1
        }
        guard ready else {
            print("结论：数据读取或计划存储未通过检查。")
            return 1
        }
        print("结论：就绪。")
        return 0
    }

    private static func runTools() -> Int32 {
        let tools = ToolCatalog.tools + ToolCatalog.managedTools
        let payload = tools.map { tool -> Value in
            .object([
                "name": .string(tool.name),
                "title": .string(tool.title ?? ""),
                "description": .string(tool.description ?? ""),
                "read_only": .bool(tool.annotations.readOnlyHint ?? false),
            ])
        }
        do {
            print(try JSONText.encode(.array(payload)))
            return 0
        } catch {
            return fail("无法编码工具目录：\(error)")
        }
    }

    static func runPreview(_ planID: String, _ options: CLIOptions) async -> Int32 {
        do {
            let bridge = try EventKitBridge(timeZoneIdentifier: options.timeZoneID)
            let service = try makeService(bridge: bridge, options: options)
            let value = try await service.call("preview_schedule", ["plan_id": .string(planID)])
            print(try JSONText.encode(value))
            return 0
        } catch {
            return fail("生成预览失败：\(error)")
        }
    }

    // MARK: - Helpers

    static func makeService(bridge: EventKitBridge, options: CLIOptions) throws -> CalendarToolService {
        let writer = try ManagedEventKit(timeZoneID: options.timeZoneID)
        return CalendarToolService(source: bridge,
            runtime: ToolRuntime(timeZoneID: options.timeZoneID, storePath: options.storePath),
            managedFactory: { path in
                ManagedScheduleService(path: path, reader: bridge, writer: writer)
            })
    }

    static func printReport(_ report: PermissionReport) {
        print("日历权限：\(report.calendar.rawValue)")
        print("提醒事项权限：\(report.reminders.rawValue)")
        for hint in report.hints {
            print("  · \(hint)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    @discardableResult
    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }
}
