import Foundation
import Testing
@testable import BarbackCore

struct CronSupervisorTests {
    @Test func wallClockTimerActuallyLaunchesAtNextMinute() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        let id = try harness.insert(Program(name: "cron-timer", kind: .oneshot, command: "/usr/bin/true", cronExpression: "* * * * *"))
        harness.bootstrapAndSettle()
        let deadline = try #require(harness.supervisor.queue.sync { harness.supervisor.cronScheduler.nextDeadline })
        #expect(harness.waitForOneshot(id, .succeeded, timeout: 65))
        let run = try #require(harness.runs(id).first)
        #expect(run.trigger == .cron)
        #expect(run.startedAt >= deadline)
        #expect(run.startedAt.timeIntervalSince(deadline) < 60)
        #expect(harness.runs(id).count == 1)
    }

    // Move only the scheduler's time forward, keeping real process execution fast.
    private func fireNext(_ harness: SupervisorHarness) throws {
        let deadline = try #require(harness.supervisor.queue.sync { harness.supervisor.cronScheduler.nextDeadline })
        harness.supervisor.queue.sync { harness.supervisor.cronScheduler.fire(at: deadline) }
    }

    @Test func scheduledRunUsesNormalProcessHistoryAndOutput() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        let id = try harness.insert(Program(name: "cron-output", kind: .oneshot, command: "/bin/echo scheduled", confirmBeforeRun: true, cronExpression: "* * * * *"))
        harness.bootstrapAndSettle()
        #expect(harness.runs(id).isEmpty) // No launch catch-up.
        try fireNext(harness)
        #expect(harness.waitForOneshot(id, .succeeded))
        let run = try #require(harness.runs(id).first)
        #expect(run.trigger == .cron)
        #expect(run.outcome == .succeeded)
        let path = try #require(run.logPath)
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("scheduled"))
        #expect(harness.program(id)?.runCount == 1)
    }

    @Test func busyOccurrenceIsSkippedAndManualRunStaysManual() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        let id = try harness.insert(Program(name: "cron-busy", kind: .oneshot, command: "/bin/sleep 30", cronExpression: "* * * * *"))
        harness.bootstrapAndSettle()
        harness.supervisor.runOneshot(id: id)
        #expect(harness.waitForOneshot(id, .running))
        let pid = harness.pid(id)
        try fireNext(harness)
        #expect(harness.runs(id).count == 1)
        #expect(harness.runs(id).first?.trigger == .manual)
        #expect(harness.pid(id) == pid)
        harness.supervisor.cancelOneshot(id: id)
        #expect(harness.waitForOneshot(id, .cancelled))
        #expect(harness.runs(id).count == 1) // No queued run after completion.
        try fireNext(harness)
        #expect(harness.waitForOneshot(id, .running))
        #expect(harness.runs(id).count == 2)
        #expect(harness.runs(id).first?.trigger == .cron)
    }

    @Test func savedScheduleAppliesImmediatelyAndDeletionRemovesIt() throws {
        let harness = try SupervisorHarness()
        defer { harness.cleanup() }
        var program = Program(name: "cron-save", kind: .oneshot, command: "/usr/bin/true")
        program.id = try harness.insert(program)
        harness.bootstrapAndSettle()
        #expect(harness.supervisor.queue.sync { harness.supervisor.cronScheduler.nextDeadline } == nil)
        func save(_ program: Program) throws {
            let result = SupervisorHarness.Box<Result<Program, ProgramSaveError>>()
            let semaphore = DispatchSemaphore(value: 0)
            harness.supervisor.validateAndSave(program) { result.value = $0; semaphore.signal() }
            #expect(semaphore.wait(timeout: .now() + 3) == .success)
            _ = try #require(result.value).get()
        }
        program.cronExpression = "* * * * *"
        try save(program)
        #expect(harness.supervisor.queue.sync { harness.supervisor.cronScheduler.nextDeadline } != nil)
        program.enabled = false
        try save(program)
        #expect(harness.supervisor.queue.sync { harness.supervisor.cronScheduler.nextDeadline } == nil)
        program.enabled = true
        try save(program)
        let done = SupervisorHarness.Box<Bool>()
        harness.supervisor.deleteProgram(id: program.id) { done.value = true }
        #expect(harness.waitForFlag(done))
        #expect(harness.supervisor.queue.sync { harness.supervisor.cronScheduler.nextDeadline } == nil)
    }
}
