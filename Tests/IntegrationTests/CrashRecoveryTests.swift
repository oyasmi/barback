import Foundation
import Testing
@testable import BarbackCore

/// Exercises the PID+start-time double-check that crash recovery relies on
/// (design.md §3.7, A5) without needing the full `Supervisor`/AppKit stack.
struct CrashRecoveryTests {
    @Test func survivingProcessPassesDoubleCheck() throws {
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(devNull) }
        let spawned = try ProcessHost.spawn(command: "/bin/sh -c 'sleep 5'", useShell: false, directory: nil, environment: [:], outFD: devNull, errFD: devNull)
        defer { ProcessHost.sendKill(pid: spawned.pid, pgid: spawned.pgid, asGroup: true) }

        let live = LiveRecord(programId: 1, appBootId: "old-boot", state: "RUNNING", pid: spawned.pid, pgid: spawned.pgid, procStartTime: spawned.startTime)
        #expect(ProcessHost.verifyAlive(pid: live.pid!, expectedStartTime: live.procStartTime!))
    }

    @Test func pidReuseIsDetected() throws {
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(devNull) }
        let spawned = try ProcessHost.spawn(command: "/bin/sh -c 'exit 0'", useShell: false, directory: nil, environment: [:], outFD: devNull, errFD: devNull)
        // Give it time to exit and reap via a manual waitpid so it's no longer a zombie.
        var status: Int32 = 0
        _ = waitpid(spawned.pid, &status, 0)
        // Even if the pid were reused by a new process, a stale recorded startTime should
        // fail verification against whatever currently holds that pid (or the pid is just gone).
        #expect(!ProcessHost.verifyAlive(pid: spawned.pid, expectedStartTime: spawned.startTime))
    }
}
