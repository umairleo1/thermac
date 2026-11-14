import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal wrapper over the system SQLite3 library (no third-party dependencies).
final class SQLiteDB {
    let handle: OpaquePointer

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: rc, message: msg)
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close_v2(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        guard rc == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        return Statement(stmt, db: self)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }
}

final class Statement {
    private let stmt: OpaquePointer
    private unowned let db: SQLiteDB

    init(_ stmt: OpaquePointer, db: SQLiteDB) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    @discardableResult
    func bind(_ values: Any?...) -> Statement {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default: preconditionFailure("unsupported bind type \(type(of: value))")
            }
        }
        return self
    }

    /// Steps once; returns true when a row is available.
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw db.error(rc)
        }
    }

    /// Runs the statement to completion.
    func run() throws { while try step() {} }

    func double(_ col: Int32) -> Double? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, col)
    }

    func int(_ col: Int32) -> Int64? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, col)
    }

    func text(_ col: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: p)
    }
}
