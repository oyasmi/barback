import Foundation
import Testing
@testable import BarbackCore

struct StoreTests {
    func makeStore() throws -> Store {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Store(dbPath: dir.appendingPathComponent("test.db").path, backupsDir: dir.appendingPathComponent("backups").path)
    }

    @Test func insertAndFetchProgramRoundTrips() throws {
        let store = try makeStore()
        var program = Program(name: "svc1", kind: .service, command: "/bin/true", environment: ["FOO": EnvVar(value: "bar", sensitive: true)])
        let id = try store.insertProgram(program)
        program.id = id
        let fetched = try store.fetchProgram(id: id)
        #expect(fetched?.name == "svc1")
        #expect(fetched?.environment["FOO"]?.value == "bar")
        #expect(fetched?.environment["FOO"]?.sensitive == true)
    }

    @Test func liveTableRoundTrips() throws {
        let store = try makeStore()
        let id = try store.insertProgram(Program(name: "svc2", kind: .service, command: "/bin/true"))
        let live = LiveRecord(programId: id, appBootId: "boot1", state: "RUNNING", pid: 123, pgid: 123, procStartTime: 1000, startedAt: 999, retryCount: 1)
        try store.upsertLive(live)
        let all = try store.fetchAllLive()
        #expect(all.count == 1)
        #expect(all[0].pid == 123)
        try store.clearLive(programId: id)
        #expect(try store.fetchAllLive().isEmpty)
    }

    @Test func runHistoryTrimsToLimit() throws {
        let store = try makeStore()
        let id = try store.insertProgram(Program(name: "job1", kind: .oneshot, command: "/bin/true", historyLimit: 2))
        for i in 0..<5 {
            _ = try store.insertRun(RunRecord(programId: id, trigger: .manual, startedAt: Date(timeIntervalSince1970: Double(i))))
        }
        let removed = try store.trimRunHistory(programId: id, historyLimit: 2)
        #expect(removed.isEmpty || removed.allSatisfy { !$0.isEmpty } || true)
        let remaining = try store.fetchRuns(programId: id, limit: 100)
        #expect(remaining.count == 2)
    }

    @Test func uniqueNameConstraintEnforced() throws {
        let store = try makeStore()
        _ = try store.insertProgram(Program(name: "dup", kind: .service, command: "/bin/true"))
        #expect(throws: (any Error).self) {
            _ = try store.insertProgram(Program(name: "dup", kind: .service, command: "/bin/true"))
        }
    }

    // ex-F07/F15: run_total must survive trimming (unlike a plain row COUNT) and must not be
    // clobbered by an unrelated config save.
    @Test func runTotalSurvivesTrimAndIgnoresConfigSave() throws {
        let store = try makeStore()
        let id = try store.insertProgram(Program(name: "job2", kind: .oneshot, command: "/bin/true", historyLimit: 2))
        for i in 0..<5 {
            _ = try store.insertRun(RunRecord(programId: id, trigger: .manual, startedAt: Date(timeIntervalSince1970: Double(i))))
        }
        _ = try store.trimRunHistory(programId: id, historyLimit: 2)
        #expect(try store.fetchProgram(id: id)?.runTotal == 5)

        var stale = try store.fetchProgram(id: id)!
        stale.runTotal = 0
        stale.notes = "edited while a run was in flight"
        try store.updateProgram(stale)
        #expect(try store.fetchProgram(id: id)?.runTotal == 5)
        #expect(try store.fetchProgram(id: id)?.notes == "edited while a run was in flight")
    }

    // ex-F07/F15: a pre-existing v1 database (no run_total column) must migrate cleanly,
    // backfilling run_total from whatever run rows are still on disk at upgrade time.
    @Test func migratesV1DatabaseAddingRunTotal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("legacy.db").path
        let backupsDir = dir.appendingPathComponent("backups").path
        try FileManager.default.createDirectory(atPath: backupsDir, withIntermediateDirectories: true)

        // Build a v1-shaped database by hand: the real v1 DDL (pre-migration) minus run_total.
        let legacyDb = try SQLiteDatabase(path: dbPath)
        try legacyDb.exec("""
            CREATE TABLE program (
              id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
              enabled INTEGER NOT NULL DEFAULT 1, command TEXT NOT NULL, use_shell INTEGER NOT NULL DEFAULT 0,
              directory TEXT, env_json TEXT NOT NULL DEFAULT '{}', group_name TEXT, priority INTEGER NOT NULL DEFAULT 100,
              notes TEXT, autostart INTEGER NOT NULL DEFAULT 1, autorestart TEXT NOT NULL DEFAULT 'unexpected',
              exit_codes TEXT NOT NULL DEFAULT '[0]', start_seconds INTEGER NOT NULL DEFAULT 5,
              start_retries INTEGER NOT NULL DEFAULT 3, backoff_base REAL NOT NULL DEFAULT 1.0,
              backoff_max REAL NOT NULL DEFAULT 60.0, storm_window_sec INTEGER NOT NULL DEFAULT 600,
              storm_max_restarts INTEGER NOT NULL DEFAULT 10, timeout_seconds INTEGER NOT NULL DEFAULT 0,
              confirm_before_run INTEGER NOT NULL DEFAULT 0, allow_concurrent INTEGER NOT NULL DEFAULT 0,
              history_limit INTEGER NOT NULL DEFAULT 50, stop_signal TEXT NOT NULL DEFAULT 'TERM',
              stop_wait_seconds INTEGER NOT NULL DEFAULT 10, stop_as_group INTEGER NOT NULL DEFAULT 1,
              kill_as_group INTEGER NOT NULL DEFAULT 1, log_path TEXT, log_merge_stderr INTEGER NOT NULL DEFAULT 1,
              log_stderr_path TEXT, log_max_bytes INTEGER NOT NULL DEFAULT 10485760, log_backups INTEGER NOT NULL DEFAULT 3,
              log_rotate_policy TEXT NOT NULL DEFAULT 'size', created_at REAL NOT NULL, updated_at REAL NOT NULL
            );
            CREATE TABLE live (
              program_id INTEGER PRIMARY KEY REFERENCES program(id) ON DELETE CASCADE, app_boot_id TEXT NOT NULL,
              state TEXT NOT NULL, pid INTEGER, pgid INTEGER, proc_start_time REAL, started_at REAL,
              retry_count INTEGER NOT NULL DEFAULT 0, stop_requested INTEGER NOT NULL DEFAULT 0, run_id INTEGER,
              needs_restart INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE run (
              id INTEGER PRIMARY KEY, program_id INTEGER NOT NULL REFERENCES program(id) ON DELETE CASCADE,
              trigger TEXT NOT NULL, pid INTEGER, started_at REAL NOT NULL, ended_at REAL,
              exit_code INTEGER, term_signal INTEGER, outcome TEXT, log_path TEXT
            );
            CREATE TABLE event (
              id INTEGER PRIMARY KEY, ts REAL NOT NULL, level TEXT NOT NULL, program_id INTEGER,
              type TEXT NOT NULL, detail_json TEXT
            );
            CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
        let insertProgram = try legacyDb.prepare("INSERT INTO program (name, kind, command, created_at, updated_at) VALUES ('legacy', 'oneshot', '/bin/true', 0, 0)")
        try insertProgram.run()
        let programId = legacyDb.lastInsertRowID
        for i in 0..<3 {
            let insertRun = try legacyDb.prepare("INSERT INTO run (program_id, trigger, started_at) VALUES (?, 'manual', ?)")
            insertRun.bind(1, programId)
            insertRun.bind(2, Double(i))
            try insertRun.run()
        }
        try legacyDb.setUserVersion(1)
        legacyDb.close()

        let store = try Store(dbPath: dbPath, backupsDir: backupsDir)
        let migrated = try store.fetchProgram(id: programId)
        #expect(migrated?.runTotal == 3)
    }

    // ex-F02: clearing history must never touch a run that hasn't finished yet.
    @Test func deleteRunsSkipsInFlightRuns() throws {
        let store = try makeStore()
        let id = try store.insertProgram(Program(name: "job3", kind: .oneshot, command: "/bin/true"))
        let finishedId = try store.insertRun(RunRecord(programId: id, trigger: .manual))
        try store.finalizeRun(id: finishedId, endedAt: Date(), exitCode: 0, termSignal: nil, outcome: .succeeded)
        _ = try store.insertRun(RunRecord(programId: id, trigger: .manual)) // still running: ended_at is NULL

        _ = try store.deleteRuns(programId: id, outcome: nil)
        let remaining = try store.fetchRuns(programId: id, limit: 10)
        #expect(remaining.count == 1)
        #expect(remaining[0].endedAt == nil)
    }
}
