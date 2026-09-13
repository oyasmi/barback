import Foundation
import Testing
@testable import BarbackCore

/// Integration tests against the real OS process APIs (design.md §8.4). Uses `/bin/sh`
/// and `/bin/echo` directly rather than the `testchild` fixture binary to avoid depending
/// on SwiftPM's build product layout from within a test target.
struct ProcessHostTests {
    @Test func spawnAndExitIsObservedViaKqueue() async throws {
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(devNull) }
        let spawned = try ProcessHost.spawn(command: "/bin/sh -c 'exit 3'", useShell: false, directory: nil, environment: [:], outFD: devNull, errFD: devNull)

        let watcher = ExitWatcher(queue: .global())
        let exited = await withCheckedContinuation { (continuation: CheckedContinuation<BarbackCore.ExitStatus, Never>) in
            watcher.register(pid: spawned.pid, isOwnChild: true) { status in
                continuation.resume(returning: status)
            }
        }
        #expect(exited.code == 3)
    }

    @Test func verifyAliveDetectsRealProcess() throws {
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(devNull) }
        let spawned = try ProcessHost.spawn(command: "/bin/sh -c 'sleep 5'", useShell: false, directory: nil, environment: [:], outFD: devNull, errFD: devNull)
        defer { ProcessHost.sendKill(pid: spawned.pid, pgid: spawned.pgid, asGroup: true) }
        #expect(ProcessHost.verifyAlive(pid: spawned.pid, expectedStartTime: spawned.startTime))
        #expect(!ProcessHost.verifyAlive(pid: spawned.pid, expectedStartTime: spawned.startTime - 100))
    }

    // ex-F35: a zombie still answers `kill(pid, 0)` and still reports its old start time, so
    // without checking `pbi_status` this used to read as "alive" forever — the very thing
    // `reconcileLiveness`'s 300s safety net exists to catch after a missed NOTE_EXIT.
    @Test func verifyAliveDetectsZombie() async throws {
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(devNull) }
        let spawned = try ProcessHost.spawn(command: "/bin/sh -c 'exit 0'", useShell: false, directory: nil, environment: [:], outFD: devNull, errFD: devNull)
        // Deliberately not registering an ExitWatcher (which would reap it via WNOHANG) —
        // give it time to exit and sit as a zombie, unreaped, so verifyAlive sees it in that
        // exact state.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!ProcessHost.verifyAlive(pid: spawned.pid, expectedStartTime: spawned.startTime))
        var status: Int32 = 0
        _ = waitpid(spawned.pid, &status, 0) // reap it so the test doesn't leave one behind
    }

    @Test func stopAsGroupKillsChildProcesses() async throws {
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(devNull) }
        let spawned = try ProcessHost.spawn(command: "/bin/sh -c 'sleep 10000 & wait'", useShell: false, directory: nil, environment: [:], outFD: devNull, errFD: devNull)
        try await Task.sleep(nanoseconds: 200_000_000)
        ProcessHost.sendKill(pid: spawned.pid, pgid: spawned.pgid, asGroup: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!ProcessHost.verifyAlive(pid: spawned.pid, expectedStartTime: spawned.startTime))
    }
}
