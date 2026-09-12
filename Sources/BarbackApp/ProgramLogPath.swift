import Foundation
import BarbackCore

/// Where a program's output actually lands. A service writes to one long-lived file; a
/// one-shot writes one file per run, so "the log" means its most recent run.
enum ProgramLogPath {
    static func resolve(for snap: ProgramSnapshot) -> String {
        if let explicit = snap.program.logPath { return explicit }
        if snap.program.kind == .oneshot, let last = snap.lastRun?.logPath { return last }
        return (AppPaths.programsLogsDir as NSString).appendingPathComponent("\(snap.program.name).out.log")
    }
}
