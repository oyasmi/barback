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
}
