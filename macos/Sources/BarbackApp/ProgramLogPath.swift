import Foundation
import BarbackCore

/// Where a program's output actually lands. A service writes to one long-lived file; a
/// one-shot writes one file per run, so "the log" means its most recent run.
enum ProgramLogPath {
    static func resolve(for snap: ProgramSnapshot) -> String {
        // `logPath` only ever applies to a service; a one-shot's output is always the most
        // recent run's own file. Checking `logPath` first here used to mean the moment anyone
        // filled it in (even though the field no longer shows in the form for one-shots,
        // programs saved before that change may still carry a value), the log window opened a
        // path nothing ever writes to (design.md §4, ex-F11).
        if snap.program.kind == .oneshot {
            if let last = snap.lastRun?.logPath { return last }
            return (AppPaths.runsLogsDir as NSString).appendingPathComponent("\(snap.program.name).log")
        }
        // Expanded the same way `LogManager.serviceLogPaths` expands it before ever opening
        // the file — otherwise a `~`-prefixed path opens fine for the running process but the
        // log window/Finder reveal for it looks for a literal `~` directory (ex-F33).
        if let explicit = snap.program.logPath { return PathUtil.expandTilde(explicit) }
        return (AppPaths.programsLogsDir as NSString).appendingPathComponent("\(snap.program.name).out.log")
    }
}
