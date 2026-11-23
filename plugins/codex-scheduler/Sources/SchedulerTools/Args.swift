import Foundation
import MCP
import SchedulerCore

public struct ToolInputError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Typed, forgiving accessors over MCP tool arguments.
public struct Args {
    public let raw: [String: Value]

    public init(_ raw: [String: Value]?) {
        self.raw = raw ?? [:]
    }

    public var isEmpty: Bool { raw.isEmpty }

    public func value(_ key: String) -> Value? {
        guard let value = raw[key], value != .null else { return nil }
        return value
    }

    public func string(_ key: String) -> String? {
        value(key)?.stringValue
    }

    public func requiredString(_ key: String) throws -> String {
        guard let text = string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw ToolInputError("missing required string argument '\(key)'")
        }
        return text
    }

    public func int(_ key: String) -> Int? {
        guard let value = value(key) else { return nil }
        switch value {
        case .int(let value): return value
        case .double(let value): return Int(exactly: value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    public func int(_ key: String, default fallback: Int) -> Int { int(key) ?? fallback }

    public func requiredInt(_ key: String) throws -> Int {
        guard let int = int(key) else { throw ToolInputError("missing required integer argument '\(key)'") }
        return int
    }

    public func double(_ key: String) -> Double? {
        guard let value = value(key) else { return nil }
        if let double = value.doubleValue { return double }
        if let int = value.intValue { return Double(int) }
        if let text = value.stringValue { return Double(text) }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        guard let value = value(key) else { return nil }
        if let bool = value.boolValue { return bool }
        if let int = value.intValue { return int != 0 }
        if let text = value.stringValue {
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    public func bool(_ key: String, default fallback: Bool) -> Bool { bool(key) ?? fallback }

    public func stringArray(_ key: String) -> [String]? {
        guard let value = value(key) else { return nil }
        if let array = value.arrayValue { return array.compactMap { $0.stringValue } }
        if let text = value.stringValue { return [text] }
        return nil
    }

    public func array(_ key: String) -> [Value]? { value(key)?.arrayValue }

    public func object(_ key: String) -> Args? { value(key)?.objectValue.map(Args.init) }
}

// MARK: - Date parsing

/// Parses the date/time strings that tool callers are allowed to send.
///
/// Accepted forms:
/// * `2026-11-17` — a local calendar date; as a range start it means local midnight,
///   as a range end it means the end of that local day (exclusive, i.e. next midnight).
/// * `2026-11-17T14:00`, `2026-11-17 14:00`, `2026-11-17T14:00:30` — local wall time.
/// * `2026-11-17T14:00:00+08:00`, `2026-11-17T06:00:00Z` — absolute instants.
public enum InstantParser {
    public enum Role {
        case start
        case end
    }

    private static let patternsWithZone = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        "yyyy-MM-dd'T'HH:mmZZZZZ",
    ]

    private static let patternsLocal = [
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
    ]

    public static func parse(_ text: String, role: Role, math: CalendarMath) throws -> Date {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolInputError("empty date string") }

        if let local = parseLocalDate(trimmed) {
            guard let midnight = math.date(forLocalDate: local, time: LocalTime(hour: 0, minute: 0)) else {
                throw ToolInputError("cannot resolve date '\(trimmed)' in time zone \(math.identifier)")
            }
            switch role {
            case .start: return midnight
            case .end: return math.startOfNextDay(midnight)
            }
        }

        for pattern in patternsWithZone {
            if let date = formatter(pattern, timeZone: math.timeZone).date(from: trimmed) {
                return date
            }
        }
        for pattern in patternsLocal {
            if let date = formatter(pattern, timeZone: math.timeZone).date(from: trimmed) {
                return date
            }
        }
        throw ToolInputError(
            "cannot parse date '\(trimmed)'; use YYYY-MM-DD, YYYY-MM-DDTHH:mm or a full ISO-8601 timestamp with offset"
        )
    }

    public static func parseOptional(_ text: String?, role: Role, math: CalendarMath) throws -> Date? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try parse(text, role: role, math: math)
    }

    /// Parses a task deadline: a bare date is a local calendar deadline, anything else is an instant.
    public static func parseDeadline(_ text: String, math: CalendarMath) throws -> Deadline {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let local = parseLocalDate(trimmed) {
            guard math.date(forLocalDate: local) != nil else {
                throw ToolInputError("invalid local deadline date '\(trimmed)'")
            }
            return .date(local)
        }
        let instant = try parse(trimmed, role: .end, math: math)
        return .instant(instant)
    }

    public static func parseLocalDate(_ text: String) -> LocalDate? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return LocalDate(year: year, month: month, day: day)
    }

    private static func formatter(_ pattern: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        formatter.isLenient = false
        return formatter
    }
}

// MARK: - Output helpers

public enum JSON {
    /// ISO-8601 instant with an explicit offset, e.g. `2026-11-17T14:00:00+08:00`.
    public static func instant(_ date: Date, timeZone: TimeZone) -> Value {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return .string(formatter.string(from: date))
    }

    public static func object(_ pairs: [String: Value]?) -> Value {
        .object(pairs ?? [:])
    }

    public static func stringArray(_ values: [String]) -> Value {
        .array(values.map { .string($0) })
    }
}
