import Foundation
import BarbackCore

/// Bundles self logs + redacted config + event summary + system info (FR-APP-7).
enum DiagnosticsExporter {
    @MainActor
    static func export(appState: AppState, to url: URL) {
        appState.supervisor.allPrograms { programs in
            let redacted = programs.map { redact($0) }
            appState.supervisor.fetchEvents(limit: 2000, programId: nil, level: nil) { events in
                var bundle = "# Barback Diagnostics\n\n"
                bundle += "## System\n\(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
                bundle += "## Programs (redacted)\n"
                for p in redacted {
                    bundle += "- \(p.name) [\(p.kind.rawValue)] command=\(p.command)\n"
                }
                bundle += "\n## Recent Events\n"
                for e in events.prefix(500) {
                    bundle += "\(e.ts) [\(e.level.rawValue)] \(e.type.rawValue) \(e.detailJSON)\n"
                }
                if let selfLog = try? String(contentsOfFile: AppPaths.selfLogPath, encoding: .utf8) {
                    bundle += "\n## Self Log (tail)\n" + String(selfLog.suffix(20000))
                }
                try? bundle.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func redact(_ program: Program) -> Program {
        var p = program
        p.environment = p.environment.mapValues { $0.sensitive ? EnvVar(value: "***", sensitive: true) : $0 }
        return p
    }
}
