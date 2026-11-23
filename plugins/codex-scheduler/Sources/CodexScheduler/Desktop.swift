import AppKit
import AppleBridge
import Foundation
import MCP
import SchedulerCore
import SchedulerTools

@MainActor
private final class AuthorizationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        Task { @MainActor in
            do {
                let bridge = try EventKitBridge()
                let report = await bridge.requestAccess()
                CLI.printReport(report)
                exit(report.isFullyGranted ? 0 : 2)
            } catch {
                print("授权失败：\(error)")
                exit(2)
            }
        }
    }
}

extension CLI {
    @MainActor
    static func runDesktopAuthorization() {
        let app = NSApplication.shared
        let delegate = AuthorizationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(delegate) { app.run() }
    }

    static func verifyWrites(_ options: CLIOptions) async -> Int32 {
        do {
            let report = EventKitBridge.permissionReport()
            let bridge = try EventKitBridge(timeZoneIdentifier: options.timeZoneID)
            let writer = try ManagedEventKit(timeZoneID: options.timeZoneID)
            let suffix = String(UUID().uuidString.prefix(8))
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-scheduler-verification-\(suffix)")
            let service = ManagedScheduleService(path: base.appendingPathComponent("test.sqlite").path,
                                                  reader: bridge, writer: writer, testSuffix: suffix)
            let now = Date()
            var problems: [String] = []
            for kind in ManagedItem.Kind.allCases {
                let available = kind == .event ? report.canReadCalendar : report.canReadReminders
                guard available else {
                    problems.append("\(kind.rawValue) 缺少系统授权")
                    continue
                }
                do {
                    let start = if kind == .event {
                        try verificationEventStart(after: now, reader: bridge, zone: options.timeZoneID)
                    } else {
                        service.seconds(now.addingTimeInterval(172_800))
                    }
                    let item = ManagedItem(id: UUID().uuidString, taskID: "verification", kind: kind,
                                           title: "Codex Scheduler 写入验证", start: start,
                                           end: kind == .event ? start.addingTimeInterval(60) : nil)
                    print("验证专用集合 \(service.name(kind))")
                    try await verifyRoundTrip(item, service: service, zone: options.timeZoneID)
                    print("\(kind.rawValue) 创建、重试、更新、撤回及测试事项移除通过")
                } catch {
                    problems.append("\(kind.rawValue) \(error)")
                }
            }
            for problem in problems { print(problem) }
            return problems.isEmpty ? 0 : 1
        } catch {
            print("写入验证失败 \(error)")
            return 1
        }
    }

    private static func verificationEventStart(after now: Date, reader: any CalendarSource, zone: String) throws -> Date {
        let math = try CalendarMath(timeZoneIdentifier: zone)
        let grid = GridAligner(math: math, minutes: 1)
        let start = grid.ceiling(now.addingTimeInterval(86_400))
        let end = start.addingTimeInterval(6 * 86_400)
        let occupied = try reader.events(from: start, to: end, calendarIDs: nil)
            .filter { $0.availability != .free }
            .map { Interval(start: $0.start, end: $0.end) }
        for slot in IntervalOps.subtract([Interval(start: start, end: end)], occupied) {
            let candidate = grid.ceiling(slot.start)
            if candidate.addingTimeInterval(660) <= slot.end { return candidate }
        }
        throw CLIError.message("未来七天没有可供创建和改期验证的空闲时间")
    }

    private static func verifyRoundTrip(_ item: ManagedItem, service: ManagedScheduleService, zone: String) async throws {
        func execute(_ draft: [String: MCP.Value]?) async throws -> ManagedJournal {
            guard let draftID = draft?["plan_id"]?.stringValue else { throw CLIError.message("测试预览缺少标识") }
            let applied = try await service.commit(draftID) { _ in true }
            guard applied.state == .applied else { throw CLIError.message(applied.message ?? applied.state.rawValue) }
            return applied
        }
        let created = try await execute(service.draft([ScheduleChange(after: item)], zone: zone).objectValue)
        let duplicate = try await service.commit(created.draft.id) { _ in false }
        guard duplicate.completedOperations == 1 else { throw CLIError.message("重复提交测试失败") }
        var changed = item
        if item.kind == .reminder { changed.completed = true }
        else {
            changed.start = item.start.addingTimeInterval(600)
            changed.end = item.end?.addingTimeInterval(600)
        }
        let updated = try await execute(service.draft([ScheduleChange(before: item, after: changed)], zone: zone).objectValue)
        _ = try await execute(service.undo(updated.draft.id, zone: zone).objectValue)
        _ = try await execute(service.undo(created.draft.id, zone: zone).objectValue)
        guard try service.items().isEmpty else { throw CLIError.message("测试事项仍在本地记录中") }
    }
}
