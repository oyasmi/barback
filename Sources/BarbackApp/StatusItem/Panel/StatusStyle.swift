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
        /// "Everything is fine" shouldn't shout. A panel of ten healthy services used to be a
        /// wall of saturated green capsules, which spends the whole colour budget on the one
        /// state nobody needs to be alerted about — and leaves BACKOFF orange and FATAL red
        /// competing with it. A quiet state keeps its colour on the dot and the accent bar
        /// (where it stays scannable) and renders its badge in plain secondary text.
        var isQuiet = false
    }

    /// What the row's primary button does in the current state. Shared by the button itself
    /// and by the keyboard path (⌘↩), so the two can't disagree about what "primary" means.
    enum PrimaryActionKind {
        case enable
        case start
        case stop
        case forceKill
        case run
        case cancel
    }

    struct PrimaryAction {
        var kind: PrimaryActionKind
        var title: String
        var symbol: String
        var tint: Color
    }

    static func primaryAction(for snap: ProgramSnapshot) -> PrimaryAction {
        guard snap.program.kind == .service else {
            return snap.oneshotState == .running
                ? PrimaryAction(kind: .cancel, title: "中止", symbol: "stop.fill", tint: failure)
                : PrimaryAction(kind: .run, title: "运行", symbol: "play.fill", tint: active)
        }
        let state = snap.serviceState ?? .stopped
        // A disabled-but-inactive service showed a perfectly clickable "启动" even though its
        // own badge says 已停用 and "停用" is documented to mean "won't start on its own" — the
        // only consistent reading is that starting it manually first requires turning it back
        // on (design.md §6.3, ex-F06). A service disabled while still running keeps its normal
        // stop/restart controls; disabling doesn't touch anything already active.
        if !snap.program.enabled, !state.isActive {
            return PrimaryAction(kind: .enable, title: "启用", symbol: "checkmark.circle", tint: running)
        }
        switch state {
        case .stopping:
            // TERM has been sent and we are waiting it out; the only useful escalation here is
            // SIGKILL, so that is what the row offers.
            return PrimaryAction(kind: .forceKill, title: "强制终止", symbol: "bolt.fill", tint: failure)
        case .running, .starting, .backoff:
            return PrimaryAction(kind: .stop, title: "停止", symbol: "stop.fill", tint: failure)
        case .stopped, .exited, .fatal:
            return PrimaryAction(kind: .start, title: "启动", symbol: "play.fill", tint: running)
        }
    }

    // MARK: - State → presentation

    static func presentation(for snap: ProgramSnapshot) -> Presentation {
        snap.program.kind == .service ? service(snap) : oneshot(snap)
    }

    private static func service(_ snap: ProgramSnapshot) -> Presentation {
        switch snap.serviceState ?? .stopped {
        case .running:
            return Presentation(label: "运行中", color: running, symbol: "circle.fill", isQuiet: true)
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
            return Presentation(label: "成功", color: running, symbol: "checkmark.circle.fill", isQuiet: true)
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
            return Presentation(label: outcomeLabel(outcome), color: outcomeColor(outcome),
                                symbol: outcomeSymbol(outcome), isQuiet: outcome == .succeeded)
        }
    }

    // MARK: - Run outcomes

    /// Kept as a shim over `RunOutcome.displayText` now that the label lives with the enum —
    /// the history window and the config sidebar need the same words and used to print the
    /// raw case name instead.
    static func outcomeLabel(_ outcome: RunOutcome) -> String { outcome.displayText }

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

    /// Elapsed time for a still-running program, in the compact `2min` / `1h3min` shape the
    /// detail line prefixes with `up ` / `run `. Deliberately English and unspaced: it sits
    /// between `PID 1234` and `CPU 3.2%`, where a "已运行 1 小时 3 分" reads as an intrusion.
    /// Rounded to whole minutes — the figure is only refreshed when the panel opens, so a
    /// live-looking seconds digit would be stale the moment it is drawn.
    static func uptimeShort(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days)d\(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h\(minutes)min" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)min" }
        return "<1min"
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
