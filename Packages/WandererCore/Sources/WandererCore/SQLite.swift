import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

public protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// A row from a query, read by column index.
public struct Row {
    fileprivate let stmt: OpaquePointer

    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }
    public func string(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    public func optionalString(_ i: Int32) -> String? { isNull(i) ? nil : string(i) }
    public func optionalInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
    public func optionalDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    public func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: double(i)) }
    public func optionalDate(_ i: Int32) -> Date? { isNull(i) ? nil : date(i) }
}

/// Minimal, synchronous SQLite connection. Not thread-safe: use from one actor (the main actor
/// in the app). Writes are tiny (one GPS sample per second at most), so this is plenty.
public final class SQLiteConnection {
    private var db: OpaquePointer?

    /// Pass ":memory:" for an in-memory database (tests).
    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: -1, message: msg)
        }
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" { try execute("PRAGMA journal_mode = WAL") }
    }

    deinit { sqlite3_close(db) }

    private func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(db)))
    }

    /// Runs one or more statements without parameters.
    public func execute(_ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    private func prepare(_ sql: String, _ params: [SQLBindable]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        for (index, param) in params.enumerated() {
            let i = Int32(index + 1)
            let bindRC: Int32
            switch param.sqlValue {
            case .null: bindRC = sqlite3_bind_null(stmt, i)
            case .int(let v): bindRC = sqlite3_bind_int64(stmt, i, v)
            case .double(let v): bindRC = sqlite3_bind_double(stmt, i, v)
            case .text(let v): bindRC = sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            }
            guard bindRC == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw error(bindRC)
            }
        }
        return stmt
    }

    public func run(_ sql: String, _ params: SQLBindable...) throws {
        try run(sql, params: params)
    }

    public func run(_ sql: String, params: [SQLBindable]) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
    }

    public func query<T>(_ sql: String, _ params: SQLBindable..., map: (Row) throws -> T) throws -> [T] {
        try query(sql, params: params, map: map)
    }

    public func query<T>(_ sql: String, params: [SQLBindable], map: (Row) throws -> T) throws -> [T] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var results: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            results.append(try map(Row(stmt: stmt)))
        }
        return results
    }

    public func scalarInt(_ sql: String, _ params: SQLBindable...) throws -> Int? {
        try query(sql, params: params) { $0.optionalInt(0) }.first ?? nil
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int {
        get { (try? scalarInt("PRAGMA user_version")) ?? 0 }
    }

    public func setUserVersion(_ v: Int) throws { try execute("PRAGMA user_version = \(v)") }
}
