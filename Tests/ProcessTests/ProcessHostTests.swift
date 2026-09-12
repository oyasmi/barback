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
