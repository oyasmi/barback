import Foundation
import Testing
@testable import BarbackCore

/// The panel's CPU readout is a difference between two samples, so it only exists once a
/// pid has been sampled twice. Sampling once per panel open (and clearing history on close)
/// therefore pinned every program at "0.0%" no matter how busy it was — these tests hold the
/// two halves of the fix: the baseline reports "unknown", and a spinning child reports a
/// real figure on the next sample.
struct ProcSamplerTests {
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
