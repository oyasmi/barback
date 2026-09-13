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
                    bundle += "- \(p.name) [\(p.kind.rawValue)] command=\(redactCommand(p.command))\n"
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

    /// `redact(_:)` scrubs `EnvVar.sensitive` values, but the command line is exactly where
    /// a token most often actually lives (`--api-key=…`, `curl --token abc123`) and used to
    /// go into the bundle completely unredacted (ex-F48). Heuristic, not a parser — catches
    /// `--some-key=value` / `--some-key value` shapes without understanding the target
    /// command's own syntax, and deliberately errs toward over-redacting (`--keyboard-layout`
    /// trips it too, since "keyboard" contains "key") rather than under-redacting: a
    /// diagnostics bundle losing a harmless value is a far cheaper mistake than it keeping an
    /// actual secret.
    private static let secretPattern = try? NSRegularExpression(
        pattern: #"(?i)([-]{0,2}[\w.-]*(?:key|token|secret|password|passwd|credential)[\w.-]*)([=:]\s*|\s+)(\S+)"#
    )

    static func redactCommand(_ command: String) -> String {
        guard let secretPattern else { return command }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return secretPattern.stringByReplacingMatches(in: command, range: range, withTemplate: "$1$2***")
    }
}
