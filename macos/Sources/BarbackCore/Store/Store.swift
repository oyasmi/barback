import Foundation

/// SQLite-backed persistence for programs, live snapshots, run history, events and settings.
/// Design.md §5: single file, WAL, all writes from one serial queue owned by the caller
/// (`Supervisor` on `barback.core`). This type does not itself hop queues — callers must
/// only ever touch it from that one queue.
public final class Store {
    public let dbPath: String
    public let backupsDir: String
    private var db: SQLiteDatabase
    /// Set when `init` had to recover from a corrupt database file, and how many programs
    /// were restored from the latest JSON config backup — the caller (AppDelegate) surfaces
    /// this to the user, since run/event history is lost either way (design.md §8.1).
    public private(set) var restoredProgramCount: Int?

    public init(dbPath: String, backupsDir: String) throws {
        self.dbPath = dbPath
        self.backupsDir = backupsDir
        try FileManager.default.createDirectory(atPath: (dbPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(atPath: backupsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.db = try SQLiteDatabase(path: dbPath)
        try Self.applyPragmas(db)
        try migrateIfNeeded()
        chmod(dbPath, 0o600)
    }

    /// The single writer on `barback.core` never contends with itself, but WAL still allows
    /// concurrent readers (a diagnostics export, a future second connection) to briefly hold
    /// the file locked against a writer — without a busy timeout that collision surfaces as an
    /// immediate SQLITE_BUSY error instead of a short, harmless wait (ex-F47).
    private static func applyPragmas(_ db: SQLiteDatabase) throws {
        try db.exec("PRAGMA journal_mode=WAL")
        try db.exec("PRAGMA synchronous=NORMAL")
        try db.exec("PRAGMA foreign_keys=ON")
        try db.exec("PRAGMA busy_timeout=5000")
    }

    private func migrateIfNeeded() throws {
        let ok = db.integrityCheck()
        var recovering = false
        if !ok {
            try recoverFromCorruption()
            recovering = true
        }
        // Each step is an independent `if`, not an `else if` chain — the old chain ran at
        // most one migration per launch and then stamped `Schema.currentVersion` regardless
        // of which step actually ran. A v1 database opened once `currentVersion` reached 3
        // would take the `version < 2` branch, get stamped straight to 3, and the v2→v3
        // migration would never run at all while the database claimed to already be current
        // (ex-F38). Falling through every step in order is what makes catching up from any
        // past version safe.
        if db.userVersion < 1 {
            try db.inTransaction {
                try db.exec(Schema.v1)
            }
            try db.setUserVersion(1)
        }
        if db.userVersion < 2 {
            // DDL, backfill and the version stamp used to be three separate autocommit
            // statements — if the process died right after the `ALTER TABLE` (which SQLite
            // commits immediately on its own), the next launch still saw `user_version == 1`
            // and repeated the same `ALTER TABLE`, which fails outright with "duplicate column
            // name" because the column is already there (R05). SQLite's DDL is transactional,
            // so wrapping all three in one `BEGIN IMMEDIATE`/`COMMIT` makes the whole step
            // atomic: a crash mid-migration leaves the database at v1 with no partial column,
            // safe to retry from scratch.
            try db.inTransaction {
                try db.exec("ALTER TABLE program ADD COLUMN run_total INTEGER NOT NULL DEFAULT 0")
                try db.exec("UPDATE program SET run_total = (SELECT COUNT(*) FROM run WHERE run.program_id = program.id)")
                try db.setUserVersion(2)
            }
        }
        // Future migrations: `if db.userVersion < 3 { ...; try db.setUserVersion(3) }`, each
        // preceded by a JSON backup.
        if recovering {
            restoredProgramCount = (try? restoreFromLatestConfigBackup()) ?? 0
        }
    }

    /// Quarantines the corrupt file (rather than deleting it — it may still be forensically
    /// useful) and opens a fresh database at the same path. Closing the old handle first is
    /// what makes this safe: the previous code deleted the file *after* `sqlite3_open` had
    /// already returned a handle to it, so every write for the rest of the session landed in
    /// an unlinked inode that vanished the moment the process exited (design.md §5.1).
    private func recoverFromCorruption() throws {
        db.close()
        let fm = FileManager.default
        let quarantinePath = dbPath + ".corrupt-\(Int(Date().timeIntervalSince1970))"
        try? fm.removeItem(atPath: quarantinePath)
        try? fm.moveItem(atPath: dbPath, toPath: quarantinePath)
        _ = try? fm.removeItem(atPath: dbPath + "-wal")
        _ = try? fm.removeItem(atPath: dbPath + "-shm")
        db = try SQLiteDatabase(path: dbPath)
        try Self.applyPragmas(db)
    }

    /// Re-populates the (now-empty, freshly created) program table from the newest *decodable*
    /// JSON config backup. Run/event history cannot be recovered this way — only configuration.
    ///
    /// Tries backups from newest to oldest rather than only the single newest one — a backup
    /// can itself be truncated or corrupt (the same disk trouble that took out the database
    /// could easily have hit the last write to `backupsDir` too), and giving up right there
    /// used to mean corruption recovery silently produced zero programs even when an earlier,
    /// perfectly good backup existed one file back (R15). The returned count is how many
    /// programs were actually inserted, not how many the chosen backup listed — a partial
    /// failure mid-restore no longer overstates what came back.
    private func restoreFromLatestConfigBackup() throws -> Int {
        let fm = FileManager.default
        let backups = ((try? fm.contentsOfDirectory(atPath: backupsDir)) ?? [])
            .filter { $0.hasPrefix("config-") }
            .sorted()
            .reversed()
        for candidate in backups {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: (backupsDir as NSString).appendingPathComponent(candidate))),
                  let programs = try? JSONDecoder().decode([Program].self, from: data) else { continue }
            var restored = 0
            for var program in programs {
                program.id = 0
                program.runTotal = 0
                if (try? insertProgram(program)) != nil { restored += 1 }
            }
            return restored
        }
        return 0
    }

    // MARK: - Program CRUD

    public func allProgramNames(excludingId: Int64? = nil) throws -> Set<String> {
        let stmt = try db.prepare("SELECT id, name FROM program")
        var names = Set<String>()
        while try stmt.step() {
            let id = stmt.columnInt64(0)
            if id == excludingId { continue }
            names.insert(stmt.columnString(1))
        }
        return names
    }

    public func fetchAllPrograms() throws -> [Program] {
        let stmt = try db.prepare("SELECT \(Self.programColumns) FROM program ORDER BY priority ASC, name ASC")
        var results: [Program] = []
        while try stmt.step() {
            results.append(Self.programFromRow(stmt))
        }
        return results
    }

    public func fetchProgram(id: Int64) throws -> Program? {
        let stmt = try db.prepare("SELECT \(Self.programColumns) FROM program WHERE id = ?")
        stmt.bind(1, id)
        guard try stmt.step() else { return nil }
        return Self.programFromRow(stmt)
    }

    @discardableResult
    public func insertProgram(_ program: Program) throws -> Int64 {
        var p = program
        p.createdAt = Date()
        p.updatedAt = p.createdAt
        let stmt = try db.prepare("""
            INSERT INTO program (\(Self.programColumns.replacingOccurrences(of: "id, ", with: "")))
            VALUES (\(Array(repeating: "?", count: Self.programColumnCount - 1).joined(separator: ",")))
            """)
        Self.bindProgram(stmt, p, includeId: false)
        try stmt.run()
        return db.lastInsertRowID
    }

    /// `run_total` is a lifetime counter Store itself maintains (`incrementRunTotal`), never
    /// something the config form edits — excluded here so saving a draft opened before a run
    /// just finished can't silently roll the counter back to the value it read (design.md §3.4).
    public func updateProgram(_ program: Program) throws {
        var p = program
        p.updatedAt = Date()
        let assignments = Self.updatableColumnNames.map { "\($0) = ?" }.joined(separator: ", ")
        let stmt = try db.prepare("UPDATE program SET \(assignments) WHERE id = ?")
        Self.bindProgram(stmt, p, includeId: false, includeRunTotal: false)
        stmt.bind(Int32(Self.updatableColumnNames.count + 1), p.id)
        try stmt.run()
    }

    public func deleteProgram(id: Int64) throws {
        let stmt = try db.prepare("DELETE FROM program WHERE id = ?")
        stmt.bind(1, id)
        try stmt.run()
    }

    // MARK: - Live table

    public func upsertLive(_ live: LiveRecord) throws {
        let stmt = try db.prepare("""
            INSERT INTO live (program_id, app_boot_id, state, pid, pgid, proc_start_time, started_at, retry_count, stop_requested, run_id, needs_restart)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(program_id) DO UPDATE SET
              app_boot_id=excluded.app_boot_id, state=excluded.state, pid=excluded.pid, pgid=excluded.pgid,
              proc_start_time=excluded.proc_start_time, started_at=excluded.started_at, retry_count=excluded.retry_count,
              stop_requested=excluded.stop_requested, run_id=excluded.run_id, needs_restart=excluded.needs_restart
            """)
        stmt.bind(1, live.programId)
        stmt.bind(2, live.appBootId)
        stmt.bind(3, live.state)
        stmt.bindOptional(4, live.pid)
        stmt.bindOptional(5, live.pgid)
        stmt.bindOptional(6, live.procStartTime)
        stmt.bindOptional(7, live.startedAt)
        stmt.bind(8, live.retryCount)
        stmt.bind(9, live.stopRequested ? 1 : 0)
        stmt.bindOptional(10, live.runId)
        stmt.bind(11, live.needsRestart ? 1 : 0)
        try stmt.run()
    }

    public func fetchAllLive() throws -> [LiveRecord] {
        let stmt = try db.prepare("SELECT program_id, app_boot_id, state, pid, pgid, proc_start_time, started_at, retry_count, stop_requested, run_id, needs_restart FROM live")
        var results: [LiveRecord] = []
        while try stmt.step() {
            results.append(LiveRecord(
                programId: stmt.columnInt64(0),
                appBootId: stmt.columnString(1),
                state: stmt.columnString(2),
                pid: stmt.columnInt32Optional(3),
                pgid: stmt.columnInt32Optional(4),
                procStartTime: stmt.columnDoubleOptional(5),
                startedAt: stmt.columnDoubleOptional(6),
                retryCount: stmt.columnInt(7),
                stopRequested: stmt.columnInt(8) != 0,
                runId: stmt.columnInt64Optional(9),
                needsRestart: stmt.columnInt(10) != 0
            ))
        }
        return results
    }

    public func clearLive(programId: Int64) throws {
        let stmt = try db.prepare("DELETE FROM live WHERE program_id = ?")
        stmt.bind(1, programId)
        try stmt.run()
    }

    // MARK: - Run history

    @discardableResult
    public func insertRun(_ run: RunRecord) throws -> Int64 {
        let stmt = try db.prepare("""
            INSERT INTO run (program_id, trigger, pid, started_at, ended_at, exit_code, term_signal, outcome, log_path)
            VALUES (?,?,?,?,?,?,?,?,?)
            """)
        stmt.bind(1, run.programId)
        stmt.bind(2, run.trigger.rawValue)
        stmt.bindOptional(3, run.pid)
        stmt.bind(4, run.startedAt.timeIntervalSince1970)
        stmt.bindOptional(5, run.endedAt?.timeIntervalSince1970)
        stmt.bindOptional(6, run.exitCode)
        stmt.bindOptional(7, run.termSignal)
        stmt.bindOptional(8, run.outcome?.rawValue)
        stmt.bindOptional(9, run.logPath)
        try stmt.run()
        try incrementRunTotal(programId: run.programId)
        return db.lastInsertRowID
    }

    /// Bumps the program's lifetime run counter. Kept separate from `historyLimit`-bound
    /// `run` rows so "共 N 次" stays accurate after old runs are trimmed away (design.md §3.4).
    public func incrementRunTotal(programId: Int64) throws {
        let stmt = try db.prepare("UPDATE program SET run_total = run_total + 1 WHERE id = ?")
        stmt.bind(1, programId)
        try stmt.run()
    }

    public func finalizeRun(id: Int64, endedAt: Date, exitCode: Int32?, termSignal: Int32?, outcome: RunOutcome) throws {
        let stmt = try db.prepare("UPDATE run SET ended_at=?, exit_code=?, term_signal=?, outcome=? WHERE id=?")
        stmt.bind(1, endedAt.timeIntervalSince1970)
        stmt.bindOptional(2, exitCode)
        stmt.bindOptional(3, termSignal)
        stmt.bind(4, outcome.rawValue)
        stmt.bind(5, id)
        try stmt.run()
    }

    /// A one-shot's output file is named after the run id, so its path can only be written
    /// back once the row exists (see `Supervisor.spawnOneshot`).
    public func setRunLogPath(id: Int64, path: String) throws {
        let stmt = try db.prepare("UPDATE run SET log_path=? WHERE id=?")
        stmt.bind(1, path)
        stmt.bind(2, id)
        try stmt.run()
    }

    /// Every output file this program's runs own, so deleting the program can take its logs
    /// with it instead of leaving orphans in `runs/` forever.
    public func fetchRunLogPaths(programId: Int64) throws -> [String] {
        let stmt = try db.prepare("SELECT log_path FROM run WHERE program_id = ? AND log_path IS NOT NULL")
        stmt.bind(1, programId)
        var paths: [String] = []
        while try stmt.step() {
            if let p = stmt.columnStringOptional(0) { paths.append(p) }
        }
        return paths
    }

    public func fetchRuns(programId: Int64, limit: Int = 100) throws -> [RunRecord] {
        let stmt = try db.prepare("SELECT id, program_id, trigger, pid, started_at, ended_at, exit_code, term_signal, outcome, log_path FROM run WHERE program_id = ? ORDER BY started_at DESC LIMIT ?")
        stmt.bind(1, programId)
        stmt.bind(2, limit)
        return try readRuns(stmt)
    }

    public func fetchAllRuns(limit: Int = 500) throws -> [RunRecord] {
        let stmt = try db.prepare("SELECT id, program_id, trigger, pid, started_at, ended_at, exit_code, term_signal, outcome, log_path FROM run ORDER BY started_at DESC LIMIT ?")
        stmt.bind(1, limit)
        return try readRuns(stmt)
    }

    private func readRuns(_ stmt: SQLiteStatement) throws -> [RunRecord] {
        var results: [RunRecord] = []
        while try stmt.step() {
            results.append(RunRecord(
                id: stmt.columnInt64(0),
                programId: stmt.columnInt64(1),
                trigger: RunTrigger(rawValue: stmt.columnString(2)) ?? .manual,
                pid: stmt.columnInt32Optional(3),
                startedAt: Date(timeIntervalSince1970: stmt.columnDouble(4)),
                endedAt: stmt.columnDoubleOptional(5).map(Date.init(timeIntervalSince1970:)),
                exitCode: stmt.columnInt32Optional(6),
                termSignal: stmt.columnInt32Optional(7),
                outcome: stmt.columnStringOptional(8).flatMap(RunOutcome.init(rawValue:)),
                logPath: stmt.columnStringOptional(9)
            ))
        }
        return results
    }

    /// Deletes completed runs matching the given filters, returning their log paths so the
    /// caller can remove the output files too. Runs still in flight (`ended_at IS NULL`) are
    /// never touched, so clearing history can never orphan an active process's bookkeeping.
    ///
    /// Filters the same `WHERE` directly in both the SELECT (to collect log paths) and the
    /// DELETE, rather than collecting ids and deleting `WHERE id IN (?,?,...)` — a program
    /// with enough history could build a placeholder list past SQLite's ~32766-variable limit,
    /// at which point `prepare` failed, the `try?` at the call site swallowed it, and "清空
    /// 历史" silently did nothing (ex-F46).
    public func deleteRuns(programId: Int64?, outcome: RunOutcome?) throws -> [String] {
        var predicate = "ended_at IS NOT NULL"
        if programId != nil { predicate += " AND program_id = ?" }
        if outcome != nil { predicate += " AND outcome = ?" }

        let selectStmt = try db.prepare("SELECT log_path FROM run WHERE \(predicate)")
        Self.bindRunFilter(selectStmt, programId: programId, outcome: outcome)
        var paths: [String] = []
        while try selectStmt.step() {
            if let p = selectStmt.columnStringOptional(0) { paths.append(p) }
        }

        let deleteStmt = try db.prepare("DELETE FROM run WHERE \(predicate)")
        Self.bindRunFilter(deleteStmt, programId: programId, outcome: outcome)
        try deleteStmt.run()
        return paths
    }

    private static func bindRunFilter(_ stmt: SQLiteStatement, programId: Int64?, outcome: RunOutcome?) {
        var idx: Int32 = 1
        if let programId { stmt.bind(idx, programId); idx += 1 }
        if let outcome { stmt.bind(idx, outcome.rawValue); idx += 1 }
    }

    /// Deletes runs beyond `historyLimit` for a program (FIFO), returning their log paths
    /// so the caller can remove the output files too (design.md §3.4).
    ///
    /// Expressed as one `NOT IN (subquery)` predicate reused for both the SELECT and the
    /// DELETE, so the parameter count stays fixed regardless of how many rows are being
    /// trimmed — the same unbounded-`IN`-list hazard as `deleteRuns` above (ex-F46).
    public func trimRunHistory(programId: Int64, historyLimit: Int) throws -> [String] {
        let keepSubquery = "SELECT id FROM run WHERE program_id = ? ORDER BY started_at DESC LIMIT ?"
        let selectStmt = try db.prepare("SELECT log_path FROM run WHERE program_id = ? AND id NOT IN (\(keepSubquery))")
        selectStmt.bind(1, programId)
        selectStmt.bind(2, programId)
        selectStmt.bind(3, historyLimit)
        var paths: [String] = []
        var hasRowsToTrim = false
        while try selectStmt.step() {
            hasRowsToTrim = true
            if let p = selectStmt.columnStringOptional(0) { paths.append(p) }
        }
        guard hasRowsToTrim else { return [] }

        let deleteStmt = try db.prepare("DELETE FROM run WHERE program_id = ? AND id NOT IN (\(keepSubquery))")
        deleteStmt.bind(1, programId)
        deleteStmt.bind(2, programId)
        deleteStmt.bind(3, historyLimit)
        try deleteStmt.run()
        return paths
    }

    // MARK: - Events

    /// Counts inserts since the last cap check, so a busy service doesn't pay for a full
    /// `COUNT(*)` table scan on every single event (design.md §5, event table has no index
    /// that covers COUNT).
    private var eventInsertsSinceCheck = 0

    public func insertEvent(_ event: EventRecord) throws {
        let stmt = try db.prepare("INSERT INTO event (ts, level, program_id, type, detail_json) VALUES (?,?,?,?,?)")
        stmt.bind(1, event.ts.timeIntervalSince1970)
        stmt.bind(2, event.level.rawValue)
        stmt.bindOptional(3, event.programId)
        stmt.bind(4, event.type.rawValue)
        stmt.bind(5, event.detailJSON)
        try stmt.run()

        eventInsertsSinceCheck += 1
        guard eventInsertsSinceCheck >= 256 else { return }
        eventInsertsSinceCheck = 0
        let countStmt = try db.prepare("SELECT COUNT(*) FROM event")
        _ = try countStmt.step()
        if countStmt.columnInt(0) > 20000 {
            try db.exec("DELETE FROM event WHERE id IN (SELECT id FROM event ORDER BY ts ASC LIMIT 1000)")
        }
    }

    public func fetchEvents(limit: Int = 500, programId: Int64? = nil, level: EventLevel? = nil) throws -> [EventRecord] {
        var sql = "SELECT id, ts, level, program_id, type, detail_json FROM event WHERE 1=1"
        if programId != nil { sql += " AND program_id = ?" }
        if level != nil { sql += " AND level = ?" }
        sql += " ORDER BY ts DESC LIMIT ?"
        let stmt = try db.prepare(sql)
        var idx: Int32 = 1
        if let programId {
            stmt.bind(idx, programId); idx += 1
        }
        if let level {
            stmt.bind(idx, level.rawValue); idx += 1
        }
        stmt.bind(idx, limit)
        var results: [EventRecord] = []
        while try stmt.step() {
            results.append(EventRecord(
                id: stmt.columnInt64(0),
                ts: Date(timeIntervalSince1970: stmt.columnDouble(1)),
                level: EventLevel(rawValue: stmt.columnString(2)) ?? .info,
                programId: stmt.columnInt64Optional(3),
                type: EventType(rawValue: stmt.columnString(4)) ?? .stateChanged,
                detailJSON: stmt.columnString(5)
            ))
        }
        return results
    }

    // MARK: - Settings

    public func getSetting(_ key: String) throws -> String? {
        let stmt = try db.prepare("SELECT value FROM setting WHERE key = ?")
        stmt.bind(1, key)
        guard try stmt.step() else { return nil }
        return stmt.columnString(0)
    }

    public func setSetting(_ key: String, _ value: String) throws {
        let stmt = try db.prepare("INSERT INTO setting (key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        stmt.bind(1, key)
        stmt.bind(2, value)
        try stmt.run()
    }

    // MARK: - Backups (design.md §5.1, §8.1)

    public func writeConfigBackup(_ jsonData: Data, keep: Int = 10) throws {
        let ts = Int(Date().timeIntervalSince1970)
        let path = (backupsDir as NSString).appendingPathComponent("config-\(ts).json")
        try jsonData.write(to: URL(fileURLWithPath: path), options: [.atomic])
        chmod(path, 0o600)
        let fm = FileManager.default
        let existing = ((try? fm.contentsOfDirectory(atPath: backupsDir)) ?? [])
            .filter { $0.hasPrefix("config-") }
            .sorted()
        if existing.count > keep {
            for name in existing.prefix(existing.count - keep) {
                try? fm.removeItem(atPath: (backupsDir as NSString).appendingPathComponent(name))
            }
        }
    }

    // MARK: - Row mapping

    // Deliberately omits `allow_concurrent`: `Program.allowConcurrent` was removed (the
    // reducer has refused concurrent oneshot runs unconditionally since ex-F12, so the field
    // had nothing left to gate — see OneshotStateMachineTests). The column itself stays in
    // the schema with its `DEFAULT 0` rather than via a migration — omitting it from every
    // INSERT/UPDATE here just leaves it permanently at that default, which is simpler and
    // safer than an `ALTER TABLE ... DROP COLUMN` migration for one dead field.
    private static let programColumnNames = [
        "id", "name", "kind", "enabled", "command", "use_shell", "directory", "env_json",
        "group_name", "priority", "notes", "autostart", "autorestart", "exit_codes",
        "start_seconds", "start_retries", "backoff_base", "backoff_max", "storm_window_sec",
        "storm_max_restarts", "timeout_seconds", "confirm_before_run",
        "history_limit", "stop_signal", "stop_wait_seconds", "stop_as_group", "kill_as_group",
        "log_path", "log_merge_stderr", "log_stderr_path", "log_max_bytes", "log_backups",
        "log_rotate_policy", "run_total", "created_at", "updated_at"
    ]
    private static var programColumns: String { programColumnNames.joined(separator: ", ") }
    private static var programColumnCount: Int { programColumnNames.count }
    private static let updatableColumnNames = programColumnNames.filter { $0 != "id" && $0 != "run_total" }

    private static func bindProgram(_ stmt: SQLiteStatement, _ p: Program, includeId: Bool, includeRunTotal: Bool = true) {
        var i: Int32 = 1
        if includeId { stmt.bind(i, p.id); i += 1 }
        stmt.bind(i, p.name); i += 1
        stmt.bind(i, p.kind.rawValue); i += 1
        stmt.bind(i, p.enabled ? 1 : 0); i += 1
        stmt.bind(i, p.command); i += 1
        stmt.bind(i, p.useShell ? 1 : 0); i += 1
        stmt.bindOptional(i, p.directory); i += 1
        stmt.bind(i, encodeEnv(p.environment)); i += 1
        stmt.bindOptional(i, p.groupName); i += 1
        stmt.bind(i, p.priority); i += 1
        stmt.bindOptional(i, p.notes); i += 1
        stmt.bind(i, p.autostart ? 1 : 0); i += 1
        stmt.bind(i, p.autorestart.rawValue); i += 1
        stmt.bind(i, encodeIntArray(p.exitCodes)); i += 1
        stmt.bind(i, p.startSeconds); i += 1
        stmt.bind(i, p.startRetries); i += 1
        stmt.bind(i, p.backoffBase); i += 1
        stmt.bind(i, p.backoffMax); i += 1
        stmt.bind(i, p.stormWindowSec); i += 1
        stmt.bind(i, p.stormMaxRestarts); i += 1
        stmt.bind(i, p.timeoutSeconds); i += 1
        stmt.bind(i, p.confirmBeforeRun ? 1 : 0); i += 1
        stmt.bind(i, p.historyLimit); i += 1
        stmt.bind(i, p.stopSignal); i += 1
        stmt.bind(i, p.stopWaitSeconds); i += 1
        stmt.bind(i, p.stopAsGroup ? 1 : 0); i += 1
        stmt.bind(i, p.killAsGroup ? 1 : 0); i += 1
        stmt.bindOptional(i, p.logPath); i += 1
        stmt.bind(i, p.logMergeStderr ? 1 : 0); i += 1
        stmt.bindOptional(i, p.logStderrPath); i += 1
        stmt.bind(i, p.logMaxBytes); i += 1
        stmt.bind(i, p.logBackups); i += 1
        stmt.bind(i, p.logRotatePolicy.rawValue); i += 1
        if includeRunTotal {
            stmt.bind(i, p.runTotal); i += 1
        }
        stmt.bind(i, p.createdAt.timeIntervalSince1970); i += 1
        stmt.bind(i, p.updatedAt.timeIntervalSince1970); i += 1
    }

    private static func programFromRow(_ s: SQLiteStatement) -> Program {
        Program(
            id: s.columnInt64(0),
            name: s.columnString(1),
            kind: ProgramKind(rawValue: s.columnString(2)) ?? .service,
            enabled: s.columnInt(3) != 0,
            command: s.columnString(4),
            useShell: s.columnInt(5) != 0,
            directory: s.columnStringOptional(6),
            environment: decodeEnv(s.columnString(7)),
            groupName: s.columnStringOptional(8),
            priority: s.columnInt(9),
            notes: s.columnStringOptional(10),
            autostart: s.columnInt(11) != 0,
            autorestart: AutoRestartPolicy(rawValue: s.columnString(12)) ?? .unexpected,
            exitCodes: decodeIntArray(s.columnString(13)),
            startSeconds: s.columnInt(14),
            startRetries: s.columnInt(15),
            backoffBase: s.columnDouble(16),
            backoffMax: s.columnDouble(17),
            stormWindowSec: s.columnInt(18),
            stormMaxRestarts: s.columnInt(19),
            timeoutSeconds: s.columnInt(20),
            confirmBeforeRun: s.columnInt(21) != 0,
            historyLimit: s.columnInt(22),
            stopSignal: s.columnString(23),
            stopWaitSeconds: s.columnInt(24),
            stopAsGroup: s.columnInt(25) != 0,
            killAsGroup: s.columnInt(26) != 0,
            logPath: s.columnStringOptional(27),
            logMergeStderr: s.columnInt(28) != 0,
            logStderrPath: s.columnStringOptional(29),
            logMaxBytes: s.columnInt64(30),
            logBackups: s.columnInt(31),
            logRotatePolicy: LogRotatePolicy(rawValue: s.columnString(32)) ?? .size,
            runTotal: s.columnInt(33),
            createdAt: Date(timeIntervalSince1970: s.columnDouble(34)),
            updatedAt: Date(timeIntervalSince1970: s.columnDouble(35))
        )
    }

    private static func encodeEnv(_ env: [String: EnvVar]) -> String {
        struct Wire: Codable { let v: String; let sensitive: Bool }
        let wire = env.mapValues { Wire(v: $0.value, sensitive: $0.sensitive) }
        return (try? String(data: JSONEncoder().encode(wire), encoding: .utf8)) ?? "{}"
    }

    private static func decodeEnv(_ json: String) -> [String: EnvVar] {
        struct Wire: Codable { let v: String; let sensitive: Bool }
        guard let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode([String: Wire].self, from: data) else { return [:] }
        return wire.mapValues { EnvVar(value: $0.v, sensitive: $0.sensitive) }
    }

    private static func encodeIntArray(_ arr: [Int32]) -> String {
        "[" + arr.map(String.init).joined(separator: ",") + "]"
    }

    private static func decodeIntArray(_ json: String) -> [Int32] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([Int32].self, from: data) else { return [0] }
        return arr
    }
}
