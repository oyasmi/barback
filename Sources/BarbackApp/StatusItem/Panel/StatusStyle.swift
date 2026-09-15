import AppKit
import SwiftUI
import BarbackCore

/// The status panel's visual vocabulary. Every place that paints a state — the dot, the
/// badge, the row accent, the summary chips — asks here, so they can never disagree about
/// what "重试中" looks like. State is carried by **shape and wording as well as colour**
/// (design.md §6.3), never by colour alone.
enum StatusStyle {

    // MARK: - Palette

    /// System colours, so the panel tracks light/dark mode and "increase contrast".
    static let running = Color(nsColor: .systemGreen)
    static let transitioning = Color(nsColor: .systemOrange)
    static let failure = Color(nsColor: .systemRed)
    static let active = Color(nsColor: .controlAccentColor)
    static let neutral = Color(nsColor: .secondaryLabelColor)

    struct Presentation {
        var label: String
        var color: Color
        var symbol: String
        /// Transitional states show a spinner in place of the glyph — motion reads as "working".
        var isBusy = false
    }

    // MARK: - State → presentation

    static func presentation(for snap: ProgramSnapshot) -> Presentation {
        snap.program.kind == .service ? service(snap) : oneshot(snap)
    }

    private static func service(_ snap: ProgramSnapshot) -> Presentation {
        switch snap.serviceState ?? .stopped {
        case .running:
            return Presentation(label: "运行中", color: running, symbol: "circle.fill")
        case .starting:
            return Presentation(label: "启动中", color: transitioning, symbol: "circle.bottomhalf.filled", isBusy: true)
        case .backoff:
            let label = snap.program.startRetries > 0
                ? "重试 \(snap.retryCount)/\(snap.program.startRetries)"
                : "重试中"
            // No spinner: a backoff wait is measured in seconds, and the row shows the
            // countdown itself, which says more than indeterminate motion would.
            return Presentation(label: label, color: transitioning, symbol: "arrow.clockwise.circle.fill")
        case .stopping:
            return Presentation(label: "停止中", color: transitioning, symbol: "circle.bottomhalf.filled", isBusy: true)
        case .stopped:
            return Presentation(label: "已停止", color: neutral, symbol: "circle")
        case .exited:
            return Presentation(label: "已退出", color: neutral, symbol: "circle")
        case .fatal:
            return Presentation(label: "启动失败", color: failure, symbol: "exclamationmark.triangle.fill")
        }
    }

    private static func oneshot(_ snap: ProgramSnapshot) -> Presentation {
        switch snap.oneshotState ?? .idle {
        case .running:
            return Presentation(label: "执行中", color: active, symbol: "circle.dotted", isBusy: true)
        case .succeeded:
            return Presentation(label: "成功", color: running, symbol: "checkmark.circle.fill")
        case .failed:
            return Presentation(label: "失败", color: failure, symbol: "xmark.circle.fill")
        case .timeout:
            return Presentation(label: "超时", color: transitioning, symbol: "exclamationmark.circle.fill")
        case .cancelled:
            return Presentation(label: "已中止", color: neutral, symbol: "minus.circle.fill")
        case .idle:
            guard let outcome = snap.lastRun?.outcome else {
                return Presentation(label: "尚未执行", color: neutral, symbol: "circle")
            }
            return Presentation(label: outcomeLabel(outcome), color: outcomeColor(outcome), symbol: outcomeSymbol(outcome))
        }
    }

    // MARK: - Run outcomes

    static func outcomeLabel(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .succeeded: return "成功"
        case .failed: return "失败"
        case .timeout: return "超时"
        case .cancelled: return "已中止"
        case .unknown: return "结果未知"
        }
    }

    static func outcomeColor(_ outcome: RunOutcome) -> Color {
        switch outcome {
        case .succeeded: return running
        case .failed: return failure
        case .timeout: return transitioning
        case .cancelled, .unknown: return neutral
        }
    }

    static func outcomeSymbol(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .timeout: return "exclamationmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    // MARK: - Formatting

    /// Human uptime, two units at most: "2 天 3 小时" / "12 分 05 秒".
    static func uptime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if days > 0 { return hours > 0 ? "\(days) 天 \(hours) 小时" : "\(days) 天" }
        if hours > 0 { return minutes > 0 ? "\(hours) 小时 \(minutes) 分" : "\(hours) 小时" }
        if minutes > 0 { return "\(minutes) 分 \(seconds) 秒" }
        return "\(seconds) 秒"
    }

    /// Same as `uptime`, but rounded to whole minutes — for the still-running readout, which
    /// is only refreshed once per panel open and so should never show a stale-looking seconds
    /// digit.
    static func uptimeMinutes(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days) 天 \(hours) 小时" : "\(days) 天" }
        if hours > 0 { return minutes > 0 ? "\(hours) 小时 \(minutes) 分" : "\(hours) 小时" }
        if minutes > 0 { return "\(minutes) 分钟" }
        return "不到 1 分钟"
    }

    /// Run durations, which are usually seconds rather than days.
    static func runDuration(_ interval: TimeInterval) -> String {
        if interval < 1 { return String(format: "%.0f 毫秒", interval * 1000) }
        if interval < 60 { return String(format: "%.1f 秒", interval) }
        return uptime(interval)
    }

    static func memory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        if mb >= 100 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    /// `nil` is the honest answer between the panel opening and its second sample landing:
    /// there is no window to average over yet (see `ProcSample.cpuPercent`).
    static func cpu(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        return percent < 10 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent)
    }

    /// Times from today read as a clock; older ones carry the date.
    static func timestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天 " + clockFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return "昨天 " + clockFormatter.string(from: date) }
        return dateFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
