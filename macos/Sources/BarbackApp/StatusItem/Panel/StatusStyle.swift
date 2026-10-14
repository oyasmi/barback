import AppKit
import SwiftUI
import BarbackCore

/// The status panel's visual vocabulary. Every place that paints a state — the dot, the
/// badge, the row accent, the summary chips — asks here, so they can never disagree about
/// what String(localized: "重试中") looks like. State is carried by **shape and wording as well as colour**
/// (design.md §6.3), never by colour alone.
enum StatusStyle {

    // MARK: - Palette

    /// System colours, so the panel tracks light/dark mode and "increase contrast".
    static let running = Color(nsColor: .systemGreen)
    /// Execution is transient work, distinct from a service's sustained green status.
    static let executing = Color(nsColor: .systemBlue)
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
        /// competing with it. A quiet state keeps its colour on the status glyph (and the
        /// service's accent bar) and renders its badge in plain secondary text.
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
        /// Whether the button keeps its tint at rest. Most primaries are the routine verb for
        /// a healthy row — a column of red 停止 capsules down a panel of running services spent
        /// the colour budget `isQuiet` exists to save — so they stay neutral until the row is
        /// approached. Only the verbs that answer a problem (启动 on FATAL, 强制终止 on a stuck
        /// stop) are coloured all the time.
        var isUrgent = false
    }

    static func primaryAction(for snap: ProgramSnapshot) -> PrimaryAction {
        guard snap.program.kind == .service else {
            return snap.oneshotState == .running
                ? PrimaryAction(kind: .cancel, title: String(localized: "中止"), symbol: "stop.fill", tint: failure)
                : PrimaryAction(kind: .run, title: String(localized: "运行"), symbol: "play.fill", tint: active)
        }
        let state = snap.serviceState ?? .stopped
        // A disabled-but-inactive service showed a perfectly clickable String(localized: "启动") even though its
        // own badge says 已停用 and "停用" is documented to mean "won't start on its own" — the
        // only consistent reading is that starting it manually first requires turning it back
        // on (design.md §6.3, ex-F06). A service disabled while still running keeps its normal
        // stop/restart controls; disabling doesn't touch anything already active.
        if !snap.program.enabled, !state.isActive {
            return PrimaryAction(kind: .enable, title: String(localized: "启用"), symbol: "checkmark.circle", tint: running)
        }
        switch state {
        case .stopping:
            // TERM has been sent and we are waiting it out; the only useful escalation here is
            // SIGKILL, so that is what the row offers.
            return PrimaryAction(kind: .forceKill, title: String(localized: "强制终止"), symbol: "bolt.fill", tint: failure, isUrgent: true)
        case .running, .starting, .backoff:
            return PrimaryAction(kind: .stop, title: String(localized: "停止"), symbol: "stop.fill", tint: failure)
        case .stopped, .exited, .fatal:
            return PrimaryAction(kind: .start, title: String(localized: "启动"), symbol: "play.fill", tint: running,
                                 isUrgent: state == .fatal)
        }
    }

    /// A service that is failing or waiting on someone, which the panel lifts into a 需要处理
    /// section above everything else instead of leaving it at its priority-order position.
    ///
    /// STARTING counts only while retrying: a crash loop alternates BACKOFF ↔ STARTING every
    /// few seconds, and a row that hopped between sections on each attempt would be
    /// impossible to click. A first, ordinary start is not a problem.
    static func needsAttention(_ snap: ProgramSnapshot) -> Bool {
        guard snap.program.kind == .service else { return false }
        switch snap.serviceState ?? .stopped {
        case .fatal, .backoff: return true
        case .starting: return snap.retryCount > 0
        default: return snap.needsRestart
        }
    }

    // MARK: - State → presentation

    static func presentation(for snap: ProgramSnapshot) -> Presentation {
        snap.program.kind == .service ? service(snap) : oneshot(snap)
    }

    private static func service(_ snap: ProgramSnapshot) -> Presentation {
        switch snap.serviceState ?? .stopped {
        case .running:
            return Presentation(label: String(localized: "运行中"), color: running, symbol: "circle.fill", isQuiet: true)
        case .starting:
            return Presentation(label: String(localized: "启动中"), color: transitioning, symbol: "circle.bottomhalf.filled", isBusy: true)
        case .backoff:
            let label = snap.program.startRetries > 0
                ? String(localized: "重试 \(snap.retryCount)/\(snap.program.startRetries)")
                : String(localized: "重试中")
            // No spinner: a backoff wait is measured in seconds, and the row shows the
            // countdown itself, which says more than indeterminate motion would.
            return Presentation(label: label, color: transitioning, symbol: "arrow.clockwise.circle.fill")
        case .stopping:
            return Presentation(label: String(localized: "停止中"), color: transitioning, symbol: "circle.bottomhalf.filled", isBusy: true)
        case .stopped:
            return Presentation(label: String(localized: "已停止"), color: neutral, symbol: "circle")
        case .exited:
            return Presentation(label: String(localized: "已退出"), color: neutral, symbol: "circle")
        case .fatal:
            return Presentation(label: String(localized: "启动失败"), color: failure, symbol: "exclamationmark.triangle.fill")
        }
    }

    private static func oneshot(_ snap: ProgramSnapshot) -> Presentation {
        switch snap.oneshotState ?? .idle {
        case .running:
            return Presentation(label: String(localized: "执行中"), color: executing, symbol: "circle.dotted", isBusy: true)
        case .succeeded:
            return lastOutcomePresentation(.succeeded)
        case .failed:
            return lastOutcomePresentation(.failed)
        case .timeout:
            return lastOutcomePresentation(.timeout)
        case .cancelled:
            return lastOutcomePresentation(.cancelled)
        case .idle:
            guard let outcome = snap.lastRun?.outcome else {
                return Presentation(label: String(localized: "尚未执行"), color: neutral, symbol: "terminal")
            }
            return lastOutcomePresentation(outcome)
        }
    }

    /// A completed command reports history, including after the app restores an idle row.
    /// History entries themselves keep their simple outcome labels.
    private static func lastOutcomePresentation(_ outcome: RunOutcome) -> Presentation {
        let label: String
        switch outcome {
        case .succeeded: label = String(localized: "上次成功")
        case .failed: label = String(localized: "上次失败")
        case .timeout: label = String(localized: "上次超时")
        case .cancelled: label = String(localized: "上次已中止")
        case .unknown: label = String(localized: "上次结果未知")
        }
        return Presentation(label: label, color: outcomeColor(outcome),
                            symbol: outcomeSymbol(outcome), isQuiet: outcome == .succeeded)
    }

    // MARK: - Run outcomes

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
        if days > 0 { return hours > 0 ? String(localized: "\(days) 天 \(hours) 小时") : String(localized: "\(days) 天") }
        if hours > 0 { return minutes > 0 ? String(localized: "\(hours) 小时 \(minutes) 分") : String(localized: "\(hours) 小时") }
        if minutes > 0 { return String(localized: "\(minutes) 分 \(seconds) 秒") }
        return String(localized: "\(seconds) 秒")
    }

    /// Elapsed time for a still-running program, in the compact `2min` / `1h3min` shape the
    /// detail line prefixes with `up ` / `run `. Deliberately English and unspaced: it sits
    /// between `PID 1234` and `CPU 3.2%`, where a "已运行 1 小时 3 分" reads as an intrusion.
    /// Rounded to whole minutes: the panel clock ticks once a second, but a seconds digit
    /// churning on every row is motion nobody asked for.
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
        if interval < 1 { return String(format: NSLocalizedString("%.0f 毫秒", comment: "run duration below one second"), interval * 1000) }
        if interval < 60 { return String(format: NSLocalizedString("%.1f 秒", comment: "run duration below one minute"), interval) }
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

    /// How long ago, for the last-run / last-exit figures: "12 分钟前" scans faster than a
    /// clock time someone has to subtract from now. Past a day the absolute timestamp is the
    /// more useful answer.
    static func relative(_ date: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        if elapsed < 60 { return String(localized: "刚刚") }
        if elapsed < 3600 { return String(localized: "\(elapsed / 60) 分钟前") }
        if elapsed < 86_400 { return String(localized: "\(elapsed / 3600) 小时前") }
        return timestamp(date)
    }

    /// Cumulative CPU time uses duration units rather than a percentage. Keep sub-second
    /// work visible for services that spend most of their lifetime idle.
    static func cpuTime(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        if seconds < 3600 {
            let total = Int(seconds)
            return "\(total / 60)min\(total % 60)s"
        }
        return uptimeShort(seconds)
    }

    /// Times from today read as a clock; older ones carry the date.
    static func timestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "今天 ") + clockFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天 ") + clockFormatter.string(from: date) }
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
