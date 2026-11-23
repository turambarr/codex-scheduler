import Foundation
import SchedulerCore
import SQLite3
import Darwin

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A saved plan together with the tasks it was produced from, so a later preview can
/// show titles and priorities without re-deriving them.
public struct PlanRecord: Codable, Sendable {
    public var plan: SchedulePlan
    public var tasks: [PlanTask]

    public init(plan: SchedulePlan, tasks: [PlanTask]) {
        self.plan = plan
        self.tasks = tasks
    }
}

public struct StoreError: Error, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Where the plan database lives, with a fallback for machines where the usual
/// Application Support directory is not writable (sandboxes, locked-down accounts).
public enum StoreLocation {
    public static func fallbackPath() -> String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex-scheduler/plans.sqlite")
            .path
    }

    /// Returns `preferred` when a store can actually be opened there, otherwise the
    /// user-home fallback, otherwise `preferred` so the eventual error names the
    /// location the user asked for.
    public static func resolve(preferred: String) -> String {
        if (try? PlanStore(path: preferred)) != nil { return preferred }
        let fallback = fallbackPath()
        if (try? PlanStore(path: fallback)) != nil { return fallback }
        return preferred
    }
}

/// Minimal local persistence for generated plans.
///
/// Phase 1 only needs to keep a plan long enough to be inspected by a human, so the
/// schema stores the full plan as JSON keyed by plan id. Later phases add `tasks`,
/// `blocks` and `operations` tables for confirmed state and undo.
public final class PlanStore {
    private var db: OpaquePointer?
    public let path: String

    public init(path: String) throws {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty, !FileManager.default.fileExists(atPath: directory) {
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            } catch {
                throw StoreError("cannot create store directory \(directory): \(error.localizedDescription)")
            }
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, db != nil else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw StoreError("cannot open store at \(path): \(message)")
        }
        sqlite3_busy_timeout(db, 3_000)
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS schema_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS plans (
            plan_id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        """)
        try execute("INSERT OR IGNORE INTO schema_meta (key, value) VALUES ('schema_version', '1');")
        try execute("""
        CREATE TABLE IF NOT EXISTS managed_state (
            namespace TEXT NOT NULL, key TEXT NOT NULL, payload BLOB NOT NULL,
            PRIMARY KEY (namespace, key)
        );
        CREATE TABLE IF NOT EXISTS managed_log (
            sequence INTEGER PRIMARY KEY, draft_id TEXT NOT NULL,
            created_at REAL NOT NULL, state TEXT NOT NULL, completed INTEGER NOT NULL
        );
        """)
    }

    private func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        if code != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "sqlite error \(code)"
            sqlite3_free(errorPointer)
            throw StoreError("sqlite: \(message)")
        }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func save(_ record: PlanRecord) throws {
        let plan = record.plan
        let payload = try encoder().encode(record)
        let sql = "INSERT OR REPLACE INTO plans (plan_id, created_at, payload) VALUES (?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, plan.planID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, plan.generatedAt.timeIntervalSince1970)
        _ = payload.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 3, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError("insert failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    public func load(planID: String) throws -> PlanRecord? {
        let sql = "SELECT payload FROM plans WHERE plan_id = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, planID, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let pointer = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        let data = Data(bytes: pointer, count: count)
        return try decoder().decode(PlanRecord.self, from: data)
    }

    public func recent(limit: Int = 10) throws -> [(planID: String, createdAt: Date)] {
        let sql = "SELECT plan_id, created_at FROM plans ORDER BY created_at DESC LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var result: [(String, Date)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let created = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            result.append((id, created))
        }
        return result
    }

    public func delete(planID: String) throws {
        let sql = "DELETE FROM plans WHERE plan_id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, planID, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError("delete failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    public func count() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM plans;", -1, &statement, nil) == SQLITE_OK else {
            throw StoreError("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    public func withWriteLock<T>(_ action: () async throws -> T) async throws -> T {
        let descriptor = open(path + ".write-lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw StoreError("无法打开排程写入锁") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw StoreError("有另一项日程变更正在处理，请稍后查看状态")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try await action()
    }

    public func put<T: Encodable>(_ value: T, in namespace: String, key: String) throws {
        let bytes = try JSONEncoder().encode(value)
        let sql = "INSERT OR REPLACE INTO managed_state(namespace, key, payload) VALUES (?, ?, ?)"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, namespace, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, key, -1, SQLITE_TRANSIENT)
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    public func managedValues<T: Decodable>(_ type: T.Type, in namespace: String, key: String? = nil) throws -> [T] {
        let statement = try prepare("SELECT payload FROM managed_state WHERE namespace = ? AND (? IS NULL OR key = ?) ORDER BY key")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, namespace, -1, SQLITE_TRANSIENT)
        if let key {
            sqlite3_bind_text(statement, 2, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, key, -1, SQLITE_TRANSIENT)
        }
        var results: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return results }
            guard code == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw databaseError() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            results.append(try JSONDecoder().decode(type, from: data))
        }
    }

    public func saveJournal(_ value: ManagedJournal, changedItem: ManagedItemRecord? = nil) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try put(value, in: "journal", key: value.draft.id)
            if let changedItem { try put(changedItem, in: "item", key: changedItem.id) }
            if value.state == .applied, let completion = value.draft.taskCompletion {
                try put(completion.after, in: "completion", key: completion.taskID)
            }
            let statement = try prepare("INSERT INTO managed_log(draft_id, created_at, state, completed) VALUES (?, ?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, value.draft.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(statement, 3, value.state.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 4, Int32(value.completedOperations))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError() }
        return statement
    }

    private func databaseError() -> StoreError {
        StoreError("SQLite: \(String(cString: sqlite3_errmsg(db)))")
    }
}

public struct ManagedItemRecord: Codable, Sendable {
    public let id: String
    public let current: ManagedItem?

    public init(id: String, current: ManagedItem?) {
        self.id = id
        self.current = current
    }
}
