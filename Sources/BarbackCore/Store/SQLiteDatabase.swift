import CSQLite
import Foundation

public enum SQLiteError: Error, LocalizedError, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m), .prepareFailed(let m), .stepFailed(let m), .bindFailed(let m):
            return m
        }
    }
}

/// A single SQLite statement bound and stepped by callers. Not thread-safe on its own;
/// callers are expected to run all database access on one serial queue (Store does this).
public final class SQLiteStatement {
    fileprivate var handle: OpaquePointer?

    fileprivate init(_ handle: OpaquePointer?) {
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    public func bind(_ index: Int32, _ value: Int64) { sqlite3_bind_int64(handle, index, value) }
    public func bind(_ index: Int32, _ value: Int) { sqlite3_bind_int64(handle, index, Int64(value)) }
    public func bind(_ index: Int32, _ value: Double) { sqlite3_bind_double(handle, index, value) }
    public func bind(_ index: Int32, _ value: String) {
        sqlite3_bind_text(handle, index, value, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }
    public func bindNull(_ index: Int32) { sqlite3_bind_null(handle, index) }

    public func bindOptional(_ index: Int32, _ value: Int64?) {
        if let value { bind(index, value) } else { bindNull(index) }
    }
    public func bindOptional(_ index: Int32, _ value: Int?) {
        if let value { bind(index, value) } else { bindNull(index) }
    }
    public func bindOptional(_ index: Int32, _ value: Int32?) {
        if let value { bind(index, Int64(value)) } else { bindNull(index) }
    }
    public func bindOptional(_ index: Int32, _ value: String?) {
        if let value { bind(index, value) } else { bindNull(index) }
    }
    public func bindOptional(_ index: Int32, _ value: Double?) {
        if let value { bind(index, value) } else { bindNull(index) }
    }

    @discardableResult
    public func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        // `sqlite3_errmsg` reads off the connection, not the statement, but `handle`'s
        // connection is exactly the one this statement ran against — a bare result code was
        // all diagnostics export or `logSelf` ever had to go on otherwise (ex-F47).
        let message = sqlite3_errmsg(sqlite3_db_handle(handle)).map { String(cString: $0) } ?? "unknown error"
        throw SQLiteError.stepFailed("step failed (\(rc)): \(message)")
    }

    public func run() throws {
        _ = try step()
    }

    public func reset() { sqlite3_reset(handle) }

    public func columnInt64(_ index: Int32) -> Int64 { sqlite3_column_int64(handle, index) }
    public func columnInt(_ index: Int32) -> Int { Int(sqlite3_column_int64(handle, index)) }
    public func columnDouble(_ index: Int32) -> Double { sqlite3_column_double(handle, index) }
    public func columnString(_ index: Int32) -> String {
        guard let cstr = sqlite3_column_text(handle, index) else { return "" }
        return String(cString: cstr)
    }
    public func columnIsNull(_ index: Int32) -> Bool { sqlite3_column_type(handle, index) == SQLITE_NULL }

    public func columnInt64Optional(_ index: Int32) -> Int64? { columnIsNull(index) ? nil : columnInt64(index) }
    public func columnIntOptional(_ index: Int32) -> Int? { columnIsNull(index) ? nil : columnInt(index) }
    public func columnInt32Optional(_ index: Int32) -> Int32? { columnIsNull(index) ? nil : Int32(columnInt64(index)) }
    public func columnStringOptional(_ index: Int32) -> String? { columnIsNull(index) ? nil : columnString(index) }
    public func columnDoubleOptional(_ index: Int32) -> Double? { columnIsNull(index) ? nil : columnDouble(index) }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper over the C SQLite API. All access must happen from one thread/queue
/// (design.md §5.1: single writer on the `barback.core` serial queue).
public final class SQLiteDatabase {
    private var db: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open(path, &handle)
        guard rc == SQLITE_OK else {
            // `sqlite3_open` can return a non-null handle even on failure (its docs call this
            // out explicitly, precisely so the caller can read `sqlite3_errmsg` off it) —
            // leaving it unclosed here leaked it, one open file descriptor at a time, on every
            // failed open the corruption-recovery path was specifically written to expect.
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError.openFailed("sqlite3_open failed: \(rc)")
        }
        db = handle
    }

    deinit {
        close()
    }

    /// Explicit close, so corruption recovery can release the handle on the (possibly bad)
    /// file before renaming it out of the way — waiting for `deinit` would run too late,
    /// after a replacement `SQLiteDatabase` has already opened the same path.
    ///
    /// `sqlite3_close` (not `_v2`) fails with SQLITE_BUSY and leaves the handle open if any
    /// prepared statement on it hasn't been finalized yet — silently, since the return value
    /// was never checked — which is exactly the situation `recoverFromCorruption` cannot
    /// afford: it assumes this call always actually closes the file before renaming it out of
    /// the way. `_v2` instead marks the handle a zombie and finishes closing once its last
    /// statement finalizes, so the rename that follows is safe either way (ex-F47).
    public func close() {
        guard let handle = db else { return }
        sqlite3_close_v2(handle)
        db = nil
    }

    public func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let message = errmsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errmsg)
            throw SQLiteError.stepFailed("exec failed (\(rc)): \(message) — sql: \(sql)")
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var handle: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &handle, nil)
        guard rc == SQLITE_OK else {
            let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown error"
            throw SQLiteError.prepareFailed("prepare failed (\(rc)): \(message) — sql: \(sql)")
        }
        return SQLiteStatement(handle)
    }

    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(db)
    }

    public func inTransaction<T>(_ body: () throws -> T) throws -> T {
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

    public var userVersion: Int32 {
        get {
            (try? prepare("PRAGMA user_version"))
                .flatMap { stmt -> Int32? in
                    guard (try? stmt.step()) == true else { return nil }
                    return Int32(stmt.columnInt64(0))
                } ?? 0
        }
    }

    public func setUserVersion(_ version: Int32) throws {
        try exec("PRAGMA user_version = \(version)")
    }

    /// `quick_check` skips the index cross-validation `integrity_check` does, which is one to
    /// two orders of magnitude faster on a database that has grown to tens of MB of run/event
    /// history — and this runs on every launch, before any service is started (design.md §5.1).
    public func integrityCheck() -> Bool {
        guard let stmt = try? prepare("PRAGMA quick_check") else { return false }
        guard (try? stmt.step()) == true else { return false }
        return stmt.columnString(0) == "ok"
    }
}
