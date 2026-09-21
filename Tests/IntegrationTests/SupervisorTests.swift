import Foundation
import Testing
@testable import BarbackCore

/// End-to-end supervision against real processes: the orchestration layer that sits between
/// the (separately unit-tested) reducers and the OS — spawning, the stop handshake, run
/// bookkeeping, delete-while-running, and crash adoption (requirements.md A4/A5/A6).
struct SupervisorTests {

    @Test func startsAndStopsAService() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        let id = try harness.insert(.longRunningService(name: "svc-startstop"))
        harness.bootstrapAndSettle()

        harness.supervisor.start(id: id)
        #expect(harness.waitForService(id, .running))
        let pid = try #require(harness.pid(id))
        #expect(kill(pid, 0) == 0)

        harness.supervisor.stop(id: id)
        #expect(harness.waitForService(id, .stopped))
        #expect(harness.pid(id) == nil)
        #expect(harness.waitForExit(pid: pid))
    }

    @Test func autostartsOnBootstrap() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        var program = Program.longRunningService(name: "svc-autostart")
        program.autostart = true
        let id = try harness.insert(program)

        harness.bootstrapAndSettle()
        #expect(harness.waitForService(id, .running))
    }

    @Test func restartReplacesTheProcess() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        let id = try harness.insert(.longRunningService(name: "svc-restart"))
        harness.bootstrapAndSettle()

        harness.supervisor.start(id: id)
        #expect(harness.waitForService(id, .running))
        let firstPid = try #require(harness.pid(id))

        harness.supervisor.restart(id: id)
        // The stop has to complete before the restart spawns, so this necessarily observes a
        // *different* pid rather than the same process surviving (design.md §3.5).
        #expect(harness.waitForRunningPid(id, other: firstPid))
        #expect(harness.waitForExit(pid: firstPid))
    }

    /// ex-F45 / design.md §3.7: the row may only disappear once the process it owns has
    /// actually stopped, otherwise nothing is left to escalate the stop and the process leaks.
    @Test func deletingARunningProgramStopsItFirst() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        let id = try harness.insert(.longRunningService(name: "svc-delete"))
        harness.bootstrapAndSettle()

        harness.supervisor.start(id: id)
        #expect(harness.waitForService(id, .running))
        let pid = try #require(harness.pid(id))

        let done = SupervisorHarness.Box<Bool>()
        harness.supervisor.deleteProgram(id: id) { done.value = true }

        #expect(harness.waitForFlag(done))
        #expect(harness.program(id) == nil)
        #expect(harness.waitForExit(pid: pid))
    }

    /// A service that ignores SIGTERM must still end up STOPPED — via the stop timer's
    /// SIGKILL escalation — rather than sitting in STOPPING forever (design.md §3.5).
    @Test func stopEscalatesToKillWhenTermIsIgnored() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        var program = Program.longRunningService(name: "svc-ignores-term")
        program.command = "trap '' TERM; while true; do sleep 1; done"
        program.useShell = true
        program.stopWaitSeconds = 1
        let id = try harness.insert(program)
        harness.bootstrapAndSettle()

        harness.supervisor.start(id: id)
        #expect(harness.waitForService(id, .running))
        let pid = try #require(harness.pid(id))

        harness.supervisor.stop(id: id)
        #expect(harness.waitForService(id, .stopped, timeout: 15))
        #expect(harness.waitForExit(pid: pid))
    }

    /// Spawn never even happens here (`posix_spawn` fails on a missing executable), which is
    /// the path that has to finalize its already-inserted run row and walk backoff → FATAL
    /// (ex-F30, ex-F37).
    @Test func missingExecutableBacksOffThenGoesFatal() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        var program = Program.longRunningService(name: "svc-missing")
        program.command = "/nonexistent/barback-not-a-real-binary"
        program.startRetries = 1
        program.backoffBase = 0.05
        program.backoffMax = 0.05
        let id = try harness.insert(program)
        harness.bootstrapAndSettle()

        harness.supervisor.start(id: id)
        #expect(harness.waitForService(id, .fatal, timeout: 20))

        // `startRetries = 1` means the initial attempt plus one retry, matching supervisor's
        // own `startretries` semantics (design.md §3.3).
        let runs = harness.runs(id)
        #expect(runs.count == 2)
        let allFinalized = runs.allSatisfy { $0.endedAt != nil && $0.outcome == .failed }
        #expect(allFinalized)

        harness.supervisor.clearFatal(id: id)
        #expect(harness.waitForService(id, .stopped))
    }

    /// A service's run rows every one carry the *same* `log_path` — its single
    /// `programs/<name>.out.log` — so trimming history to `historyLimit` must not treat that
    /// path as something the discarded row owned and delete it (design.md §4).
    @Test func trimmingServiceHistoryKeepsTheLiveLogFile() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        var program = Program.longRunningService(name: "svc-trim", seconds: 1)
        program.historyLimit = 1
        let id = try harness.insert(program)
        harness.bootstrapAndSettle()

        // Two short runs, so finalizing the second trims the first out of history.
        for _ in 0..<2 {
            harness.supervisor.start(id: id)
            #expect(harness.waitForService(id, .running))
            #expect(harness.waitForService(id, .exited, timeout: 10))
        }

        #expect(harness.runs(id).count == 1)
        let logPath = (harness.logsDir as NSString).appendingPathComponent("programs/svc-trim.out.log")
        #expect(FileManager.default.fileExists(atPath: logPath))
    }

    // MARK: - One-shots

    /// Covers the run row end to end, including `log_path`: the path is only known after the
    /// row exists (the file is named after the run id) and nothing used to write it back, so
    /// every one-shot's output was on disk but unreachable from the UI (ONE-4).
    @Test func oneshotRecordsItsRunAndOutput() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        let id = try harness.insert(.oneshot(name: "cmd-echo", command: "/bin/sh -c 'echo barback-hello'"))
        harness.bootstrapAndSettle()

        harness.supervisor.runOneshot(id: id)
        #expect(harness.waitForOneshot(id, .succeeded))

        let runs = harness.runs(id)
        #expect(runs.count == 1)
        let run = try #require(runs.first)
        #expect(run.outcome == .succeeded)
        #expect(run.endedAt != nil)
        let logPath = try #require(run.logPath)
        let output = try String(contentsOfFile: logPath, encoding: .utf8)
        #expect(output.contains("barback-hello"))
        #expect(harness.program(id)?.lastRun?.logPath == logPath)
    }

    @Test func oneshotFailureIsRecorded() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        let id = try harness.insert(.oneshot(name: "cmd-fail", command: "/bin/sh -c 'exit 7'"))
        harness.bootstrapAndSettle()

        harness.supervisor.runOneshot(id: id)
        #expect(harness.waitForOneshot(id, .failed))
        #expect(harness.runs(id).first?.exitCode == 7)
    }

    @Test func oneshotTimesOut() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        let id = try harness.insert(.oneshot(name: "cmd-timeout", command: "/bin/sh -c 'sleep 30'", timeoutSeconds: 1))
        harness.bootstrapAndSettle()

        harness.supervisor.runOneshot(id: id)
        #expect(harness.waitForOneshot(id, .timeout, timeout: 20))
        #expect(harness.runs(id).first?.outcome == .timeout)
    }

    /// ex-F12: the runtime tracks a single pid, so a second run while one is in flight has to
    /// be refused rather than silently overwriting the first one's bookkeeping.
    @Test func oneshotRefusesToRunTwiceAtOnce() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        let id = try harness.insert(.oneshot(name: "cmd-serial", command: "/bin/sh -c 'sleep 2'"))
        harness.bootstrapAndSettle()

        harness.supervisor.runOneshot(id: id)
        #expect(harness.waitForOneshot(id, .running))
        harness.supervisor.runOneshot(id: id)
        #expect(harness.waitForOneshot(id, .succeeded, timeout: 20))
        #expect(harness.runs(id).count == 1)
    }

    // MARK: - Crash recovery (requirements.md A5)

    @Test func relaunchAdoptsTheSurvivingProcess() throws {
        let first = try SupervisorHarness()
        // Registered before anything can fail, so a blown assertion can't leave `sleep 30`
        // running. `defer`s unwind last-in-first-out, so the adopting instance tidies up first.
        defer { first.cleanup() }
        let id = try first.insert(.longRunningService(name: "svc-adopt"))
        first.bootstrapAndSettle()
        first.supervisor.start(id: id)
        #expect(first.waitForService(id, .running))
        let originalPid = try #require(first.pid(id))

        // No stop, no termination handshake — exactly what `kill -9` on Barback itself leaves
        // behind: a live child and a `live` row describing it.
        let second = try first.relaunch()
        defer { second.cleanup() }
        second.bootstrapAndSettle()

        #expect(second.waitForService(id, .running))
        #expect(second.pid(id) == originalPid, "the survivor must be adopted, not respawned")
        #expect(second.snapshot()?.recoveredCount == 1)

        second.supervisor.dismissRecoveryNotice()
        #expect(second.waitForRecoveryNoticeCleared())

        // And the adopted process is genuinely under the new instance's control.
        second.supervisor.stop(id: id)
        #expect(second.waitForService(id, .stopped, timeout: 15))
        #expect(second.waitForExit(pid: originalPid))
    }

    /// The other half of §3.7: the recorded pid is gone by the time Barback comes back. The
    /// abandoned run has to be settled as `unknown`, and the service routed through its normal
    /// autorestart policy rather than left sitting idle because nobody was watching (ex-F42).
    @Test func relaunchRestartsAServiceThatDiedWhileBarbackWasGone() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        var program = Program.longRunningService(name: "svc-died")
        program.autorestart = .always
        let id = try harness.insert(program)

        // A `live` row left behind by a crashed instance, describing a process that has since
        // exited — spawn one and reap it so the pid is genuinely dead.
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(devNull) }
        let dead = try ProcessHost.spawn(
            command: "/bin/sh -c 'exit 0'", useShell: false, directory: nil,
            environment: [:], outFD: devNull, errFD: devNull
        )
        var status: Int32 = 0
        _ = waitpid(dead.pid, &status, 0)
        let runId = try harness.store.insertRun(RunRecord(programId: id, trigger: .manual, pid: dead.pid))
        try harness.store.upsertLive(LiveRecord(
            programId: id, appBootId: "crashed-instance", state: ServiceState.running.rawValue,
            pid: dead.pid, pgid: dead.pgid, procStartTime: dead.startTime,
            startedAt: Date().timeIntervalSince1970, runId: runId
        ))

        harness.bootstrapAndSettle()

        #expect(harness.snapshot()?.recoveredCount == 0, "a dead pid is not something to adopt")
        #expect(harness.waitForService(id, .running, timeout: 10))
        #expect(harness.pid(id) != dead.pid)

        let abandonedRun = harness.runs(id).first { $0.id == runId }
        let abandoned = try #require(abandonedRun)
        #expect(abandoned.outcome == .unknown)
        #expect(abandoned.endedAt != nil)
    }

    // MARK: - Config changes

    /// The default log path is derived from the program name, so a rename has to carry the
    /// existing log with it or the whole history looks like it evaporated (design.md §4).
    @Test func renamingAServiceCarriesItsLogFileAlong() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        let id = try harness.insert(.longRunningService(name: "svc-old-name"))
        harness.bootstrapAndSettle()
        harness.supervisor.start(id: id)
        #expect(harness.waitForService(id, .running))
        harness.supervisor.stop(id: id)
        #expect(harness.waitForService(id, .stopped))

        let programsDir = (harness.logsDir as NSString).appendingPathComponent("programs")
        let oldPath = (programsDir as NSString).appendingPathComponent("svc-old-name.out.log")
        #expect(FileManager.default.fileExists(atPath: oldPath))

        var renamed = try #require(harness.program(id)?.program)
        renamed.name = "svc-new-name"
        let saved = SupervisorHarness.Box<Bool>()
        harness.supervisor.validateAndSave(renamed) { result in
            if case .success = result { saved.value = true }
        }
        #expect(harness.waitForFlag(saved, timeout: 5))

        let newPath = (programsDir as NSString).appendingPathComponent("svc-new-name.out.log")
        #expect(FileManager.default.fileExists(atPath: newPath))
        #expect(!FileManager.default.fileExists(atPath: oldPath))
    }

    @Test func deletingAProgramRemovesItsRunOutput() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        let id = try harness.insert(.oneshot(name: "cmd-tidy", command: "/bin/sh -c 'echo bye'"))
        harness.bootstrapAndSettle()
        harness.supervisor.runOneshot(id: id)
        #expect(harness.waitForOneshot(id, .succeeded))
        let logPath = try #require(harness.runs(id).first?.logPath)
        #expect(FileManager.default.fileExists(atPath: logPath))

        let done = SupervisorHarness.Box<Bool>()
        harness.supervisor.deleteProgram(id: id) { done.value = true }
        #expect(harness.waitForFlag(done, timeout: 5))
        #expect(!FileManager.default.fileExists(atPath: logPath))
    }
}
