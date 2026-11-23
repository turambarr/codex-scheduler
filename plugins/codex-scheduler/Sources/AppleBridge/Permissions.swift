import EventKit
import Foundation

/// Normalised view of the EventKit authorization status, stable across macOS versions.
public enum PermissionState: String, Codable, Sendable, Equatable {
    case notDetermined = "not_determined"
    case denied
    case restricted
    case authorized
    case fullAccess = "full_access"
    case writeOnly = "write_only"
    case unknown
}

public struct PermissionReport: Codable, Sendable, Equatable {
    public var calendar: PermissionState
    public var reminders: PermissionState

    public init(calendar: PermissionState, reminders: PermissionState) {
        self.calendar = calendar
        self.reminders = reminders
    }

    /// Read access to events requires full access; write-only cannot be used to schedule.
    public var canReadCalendar: Bool {
        calendar == .fullAccess || calendar == .authorized
    }

    public var canReadReminders: Bool {
        reminders == .fullAccess || reminders == .authorized
    }

    public var isFullyGranted: Bool { canReadCalendar && canReadReminders }

    /// Human-readable remediation hints for the doctor command.
    public var hints: [String] {
        var hints: [String] = []
        if calendar == .notDetermined {
            hints.append("日历权限待授权，请按 README 从桌面启动应用。")
        } else if !canReadCalendar {
            hints.append("日历权限不可读（\(calendar.rawValue)）：到 系统设置 → 隐私与安全性 → 日历 中授权本程序。")
        }
        if reminders == .notDetermined {
            hints.append("提醒事项权限待授权，请按 README 从桌面启动应用。")
        } else if !canReadReminders {
            hints.append("提醒事项权限不可读（\(reminders.rawValue)）：到 系统设置 → 隐私与安全性 → 提醒事项 中授权本程序。")
        }
        return hints
    }
}

public enum PermissionMapper {
    public static func state(from status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .authorized: return .authorized
        @unknown default: return .unknown
        }
    }
}
