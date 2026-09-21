import Foundation
import BarbackCore

/// Turns an event's stored `detail_json` into a line someone can read.
///
/// The events window used to print the JSON verbatim — `{"code":"1"}`, `{"reason":
/// "retries_exhausted"}` — which is a fine storage format and a poor thing to put in a table
/// column next to a Chinese type name (design.md §6.6, APP-3).
enum EventPresentation {
    static func detail(for event: EventRecord) -> String {
        let fields = parse(event.detailJSON)
        guard !fields.isEmpty else { return "" }
        switch event.type {
        case .processSpawned:
            return fields["pid"].map { "PID \($0)" } ?? ""
        case .processExited:
            if let code = fields["code"] { return "退出码 \(code)" }
            if let signal = fields["signal"] { return "被信号 \(signalName(signal)) 终止" }
            return "退出码未知"
        case .spawnFailed, .logWriteFailed:
            return fields["reason"] ?? fields["error"] ?? ""
        case .restartScheduled:
            var parts: [String] = []
            if let retry = fields["retry"] { parts.append("第 \(retry) 次重试") }
            if let delay = fields["delay"], let seconds = Double(delay) {
                parts.append(String(format: "%.1f 秒后", seconds))
            }
            return parts.joined(separator: " · ")
        case .enteredFatal:
            switch fields["reason"] {
            case "retries_exhausted": return "重试次数已用尽"
            case "crash_storm": return "短时间内重启过于频繁"
            default: return fields["reason"] ?? ""
            }
        case .recoveredFromCrash, .imported:
            return fields["count"].map { "共 \($0) 项" } ?? ""
        default:
            // An unrecognised shape is still better shown than hidden — just flattened out of
            // its JSON braces.
            return fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · ")
        }
    }

    /// Detail payloads are written as `[String: String]` everywhere except the two `count`
    /// events, which write a bare number — so everything is read back through
    /// `JSONSerialization` and stringified rather than decoded into a fixed type.
    private static func parse(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var fields: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String {
                fields[key] = string
            } else if let number = value as? NSNumber {
                fields[key] = number.stringValue
            }
        }
        return fields
    }

    private static func signalName(_ raw: String) -> String {
        guard let number = Int32(raw) else { return raw }
        let names: [Int32: String] = [
            SIGTERM: "SIGTERM", SIGKILL: "SIGKILL", SIGINT: "SIGINT", SIGHUP: "SIGHUP",
            SIGQUIT: "SIGQUIT", SIGSEGV: "SIGSEGV", SIGABRT: "SIGABRT", SIGBUS: "SIGBUS",
            SIGILL: "SIGILL", SIGFPE: "SIGFPE", SIGPIPE: "SIGPIPE",
            SIGUSR1: "SIGUSR1", SIGUSR2: "SIGUSR2"
        ]
        return names[number] ?? raw
    }
}
