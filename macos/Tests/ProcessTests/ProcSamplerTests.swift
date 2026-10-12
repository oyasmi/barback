import Foundation
import Testing
@testable import BarbackCore

/// Services read lifetime CPU time from a single sample, while running one-shots still
/// need two samples to measure CPU%. Exercise both against real processes.
struct ProcSamplerTests {
    @Test func cumulativeCPUIncludesWorkBeforeFirstSampleAndSurvivesClearingHistory() async throws {
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(devNull) }
        let spawned = try ProcessHost.spawn(command: "/bin/sh -c 'while :; do :; done'", useShell: false, directory: nil, environment: [:], outFD: devNull, errFD: devNull)
        defer {
            ProcessHost.sendKill(pid: spawned.pid, pgid: spawned.pgid, asGroup: true)
            ProcSampler.clearHistory(pid: spawned.pid)
            var status: Int32 = 0
            _ = waitpid(spawned.pid, &status, 0)
        }

        // Burn CPU before the sampler has ever seen this PID, then stop the child so it
        // consumes no more CPU even though wall time continues to pass.
        try await Task.sleep(nanoseconds: 800_000_000)
        try #require(kill(spawned.pid, SIGSTOP) == 0)
        var stoppedStatus: Int32 = 0
        try #require(waitpid(spawned.pid, &stoppedStatus, WUNTRACED) == spawned.pid)
        let first = try #require(ProcSampler.sample(pid: spawned.pid))
        #expect(first.cpuPercent == nil)
        #expect(first.totalCPUSeconds > 0.3)
        #expect(first.totalCPUSeconds < 1.6)

        try await Task.sleep(nanoseconds: 200_000_000)
        ProcSampler.clearHistory(pid: spawned.pid) // Closing and reopening the panel.
        let reopened = try #require(ProcSampler.sample(pid: spawned.pid))
        #expect(reopened.cpuPercent == nil)
        #expect(abs(reopened.totalCPUSeconds - first.totalCPUSeconds) < 0.01)

        // A fresh process starts its own CPU total rather than inheriting the old run.
        let restarted = try ProcessHost.spawn(command: "/bin/sleep 5", useShell: false, directory: nil, environment: [:], outFD: devNull, errFD: devNull)
        defer {
            ProcessHost.sendKill(pid: restarted.pid, pgid: restarted.pgid, asGroup: true)
            ProcSampler.clearHistory(pid: restarted.pid)
            var status: Int32 = 0
            _ = waitpid(restarted.pid, &status, 0)
        }
        let fresh = try #require(ProcSampler.sample(pid: restarted.pid))
        #expect(fresh.totalCPUSeconds >= 0)
        #expect(fresh.totalCPUSeconds < first.totalCPUSeconds)
    }

    @Test func firstSampleHasNoCPUFigureYet() throws {
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(devNull) }
        let spawned = try ProcessHost.spawn(command: "/bin/sh -c 'sleep 5'", useShell: false, directory: nil, environment: [:], outFD: devNull, errFD: devNull)
        defer {
            ProcessHost.sendKill(pid: spawned.pid, pgid: spawned.pgid, asGroup: true)
            ProcSampler.clearHistory(pid: spawned.pid)
        }

        let first = try #require(ProcSampler.sample(pid: spawned.pid))
        #expect(first.cpuPercent == nil)
        #expect(first.rssBytes > 0)
    }

    @Test func secondSampleMeasuresABusyChild() async throws {
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(devNull) }
        let spawned = try ProcessHost.spawn(command: "/bin/sh -c 'while :; do :; done'", useShell: false, directory: nil, environment: [:], outFD: devNull, errFD: devNull)
        defer {
            ProcessHost.sendKill(pid: spawned.pid, pgid: spawned.pgid, asGroup: true)
            ProcSampler.clearHistory(pid: spawned.pid)
        }

        _ = ProcSampler.sample(pid: spawned.pid)
        try await Task.sleep(nanoseconds: 800_000_000)
        let second = try #require(ProcSampler.sample(pid: spawned.pid))
        // A spin loop saturates one core, so the honest answer is ~100%. The lower bound is
        // loose enough for a contended machine but still well above the 2.4% the un-converted
        // mach-tick arithmetic used to produce for this exact child.
        let percent = try #require(second.cpuPercent)
        #expect(percent > 60)
    }

    /// The guard against dividing a CPU delta by a near-zero wall-clock window.
    @Test func samplesTakenBackToBackReportNoFigure() throws {
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(devNull) }
        let spawned = try ProcessHost.spawn(command: "/bin/sh -c 'sleep 5'", useShell: false, directory: nil, environment: [:], outFD: devNull, errFD: devNull)
        defer {
            ProcessHost.sendKill(pid: spawned.pid, pgid: spawned.pgid, asGroup: true)
            ProcSampler.clearHistory(pid: spawned.pid)
        }

        _ = ProcSampler.sample(pid: spawned.pid)
        let immediate = try #require(ProcSampler.sample(pid: spawned.pid))
        #expect(immediate.cpuPercent == nil)
    }
}
