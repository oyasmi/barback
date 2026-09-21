import Foundation
@testable import BarbackCore

/// A real `Supervisor` wired to a scratch database and log directory.
///
/// `Supervisor` used to live in the `BarbackApp` executable target, which no test target can
/// import — so the most failure-prone code in the project (five timer dictionaries, the
/// delete-while-running handshake, the termination fallback, crash adoption) had no coverage
/// at all and the "integration" tests only ever exercised `ProcessHost`. It now lives in
/// `BarbackCore`; this harness is what lets the tests drive it.
///
/// Everything here reads state through `Supervisor.fetchSnapshot`, which answers on the core
/// queue. Nothing waits on `onSnapshot` or a `@MainActor` completion: `swift test` does not
/// drain the main dispatch queue, so anything hopping to main would simply never arrive.
final class SupervisorHarness {
    let root: URL
    let logsDir: String
    let store: Store
    let supervisor: Supervisor

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("barback-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        logsDir = root.appendingPathComponent("logs").path
        store = try Store(
            dbPath: root.appendingPathComponent("barback.db").path,
            backupsDir: root.appendingPathComponent("backups").path
        )
        // Pre-seeding the cached snapshot keeps `bootstrap` from shelling out to
        // `$SHELL -l -c 'export -p'`, which would make every test pay for the user's real
        // shell startup (and inherit whatever is in it).
        try store.setSetting("env_snapshot", "{\"PATH\":\"/usr/bin:/bin:/usr/sbin:/sbin\"}")
        supervisor = Supervisor(store: store, logsDir: logsDir)
    }

    /// Reopens the same database with a second `Supervisor`, the way a relaunch after a crash
    /// does — the first instance is deliberately left un-stopped so its children survive.
    func relaunch() throws -> SupervisorHarness {
        try SupervisorHarness(reusing: self)
    }

    private init(reusing other: SupervisorHarness) throws {
        root = other.root
        logsDir = other.logsDir
        store = try Store(
            dbPath: other.root.appendingPathComponent("barback.db").path,
            backupsDir: other.root.appendingPathComponent("backups").path
        )
        supervisor = Supervisor(store: store, logsDir: other.logsDir)
    }

    // MARK: - Setup helpers

    /// Inserts a program directly, bypassing the validator — tests want to spawn things the
    /// config form would refuse (a missing executable, for instance).
    @discardableResult
    func insert(_ program: Program) throws -> Int64 {
        try store.insertProgram(program)
    }

    func bootstrapAndSettle(timeout: TimeInterval = 5) {
        supervisor.bootstrap()
        _ = waitUntil(timeout: timeout) { self.snapshot() != nil }
    }

    // MARK: - Reading state

    func snapshot(timeout: TimeInterval = 3) -> SupervisorSnapshot? {
        let box = Box<SupervisorSnapshot>()
        let semaphore = DispatchSemaphore(value: 0)
        supervisor.fetchSnapshot { value in
            box.value = value
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    func program(_ id: Int64) -> ProgramSnapshot? {
        snapshot()?.programs.first { $0.id == id }
    }

    func serviceState(_ id: Int64) -> ServiceState? {
        program(id)?.serviceState
    }

    func oneshotState(_ id: Int64) -> OneshotState? {
        program(id)?.oneshotState
    }

    func pid(_ id: Int64) -> Int32? {
        program(id)?.pid
    }

    func runs(_ id: Int64, timeout: TimeInterval = 3) -> [RunRecord] {
        let box = Box<[RunRecord]>()
        let semaphore = DispatchSemaphore(value: 0)
        supervisor.fetchRuns(programId: id, limit: 100) { runs in
            box.value = runs
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return [] }
        return box.value ?? []
    }

    // MARK: - Waiting

    /// Polls rather than subscribing: the supervisor's own notifications are main-queue
    /// bound, and the states under test are reached by kqueue and timer callbacks that have
    /// no completion handler to await in the first place.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    func waitForService(_ id: Int64, _ state: ServiceState, timeout: TimeInterval = 5) -> Bool {
        waitUntil(timeout: timeout) { self.serviceState(id) == state }
    }

    func waitForOneshot(_ id: Int64, _ state: OneshotState, timeout: TimeInterval = 10) -> Bool {
        waitUntil(timeout: timeout) { self.oneshotState(id) == state }
    }

    func waitForRunningPid(_ id: Int64, other than: Int32, timeout: TimeInterval = 10) -> Bool {
        waitUntil(timeout: timeout) {
            self.serviceState(id) == .running && self.pid(id) != nil && self.pid(id) != than
        }
    }

    func waitForExit(pid: Int32, timeout: TimeInterval = 3) -> Bool {
        waitUntil(timeout: timeout) { kill(pid, 0) != 0 }
    }

    func waitForFlag(_ flag: Box<Bool>, timeout: TimeInterval = 10) -> Bool {
        waitUntil(timeout: timeout) { flag.value == true }
    }

    func waitForRecoveryNoticeCleared(timeout: TimeInterval = 3) -> Bool {
        waitUntil(timeout: timeout) { self.snapshot()?.recoveredCount == 0 }
    }

    // MARK: - Teardown

    /// Kills anything still running and removes the scratch directory. Tests call this from a
    /// `defer` so a failed assertion can't leave a `sleep 30` behind.
    func cleanup() {
        // Going through `stopAll` rather than straight to SIGKILL matters: a bare kill looks
        // like an unexpected exit, and an `autorestart` service would be respawned — into a
        // log directory this method is about to delete.
        supervisor.stopAll()
        waitUntil(timeout: 5) {
            let idle = self.snapshot(timeout: 1)?.programs.allSatisfy { !$0.isActive }
            return idle ?? false
        }
        if let snapshot = snapshot(timeout: 1) {
            for entry in snapshot.programs {
                guard let pid = entry.pid else { continue }
                ProcessHost.sendKill(pid: pid, pgid: pid, asGroup: true)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// `DispatchSemaphore` hands the value back across a queue boundary; a plain `var`
    /// capture isn't `Sendable`, and the wait below always happens-after the write.
    final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}

extension Program {
    /// A service that outlives the test unless something stops it.
    static func longRunningService(name: String, seconds: Int = 30) -> Program {
        Program(
            name: name,
            kind: .service,
            command: "/bin/sh -c 'sleep \(seconds)'",
            autostart: false,
            // `.never` so that a test tearing a process down with a signal can't trip an
            // autorestart on the way out; the three autorestart policies are covered
            // exhaustively (and far more cheaply) by `ServiceStateMachineTests`.
            autorestart: .never,
            // The tests care about start/stop mechanics, not about the liveness threshold, so
            // a spawned process counts as RUNNING immediately.
            startSeconds: 0
        )
    }

    static func oneshot(name: String, command: String, timeoutSeconds: Int = 0) -> Program {
        Program(
            name: name,
            kind: .oneshot,
            command: command,
            autostart: false,
            timeoutSeconds: timeoutSeconds
        )
    }
}
