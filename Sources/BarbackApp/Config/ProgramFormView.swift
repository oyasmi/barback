import SwiftUI
import BarbackCore

/// The detail pane: a fixed identity header (with an inline restart-needed advisory when it
/// applies), one continuous form (`ProgramFormBody`, design.md §6.5), and a sticky commit bar.
/// The form used to be split into three tabs (常规 / 生命周期 / 日志) to keep each page to
/// roughly one screen — with fields grouped by tier instead (a handful of always-visible ones,
/// the rest folded into `AdvancedGroup`s), the base page is short enough on its own that the
/// tab bar became pure chrome and was removed (CFG-3).
struct ProgramFormView: View {
    @Binding var program: Program
    let snapshot: ProgramSnapshot?
    let errors: [ProgramValidationError]
    let isDirty: Bool
    let isNew: Bool
    let existingGroups: [String]
    let onSave: () -> Void
    let onSaveAndRestart: () -> Void
    let onRevert: () -> Void
    let onRestartNow: () -> Void
    let onShowLog: () -> Void
    let onShowHistory: () -> Void

    private var index: FieldErrorIndex { FieldErrorIndex(errors) }
    private var isRunning: Bool { snapshot?.isActive ?? false }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let text = restartAdvisoryText {
                restartAdvisory(text: text)
            }
            Divider()
            ProgramFormBody(program: $program, index: index, existingGroups: existingGroups)
            Divider()
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(program.name.isEmpty ? "未命名" : program.name)
                        .font(.title2).bold()
                        .lineLimit(1)
                    KindBadge(kind: program.kind)
                    Toggle("启用", isOn: $program.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(program.enabled ? "点击停用" : "点击启用")
                    if !program.enabled {
                        Text("已停用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let snapshot {
                StatusPill(snap: snapshot)
            }
            Button("日志", action: onShowLog)
                .disabled(isNew)
            if program.kind == .oneshot {
                Button("历史", action: onShowHistory)
                    .disabled(isNew)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        guard let snapshot, !isNew else { return "尚未保存" }
        var parts: [String] = []
        if let pid = snapshot.pid { parts.append("PID \(pid)") }
        if let startedAt = snapshot.startedAt { parts.append("已运行 \(Self.uptime(since: startedAt))") }
        if let run = snapshot.lastRun, snapshot.program.kind == .oneshot {
            parts.append("上次 \(run.outcome?.rawValue ?? "—")")
            if let duration = run.duration { parts.append(String(format: "%.1fs", duration)) }
        }
        if let code = snapshot.lastRun?.exitCode, snapshot.program.kind == .service, !snapshot.isActive {
            parts.append("上次退出码 \(code)")
        }
        if let group = program.groupName, !group.isEmpty { parts.append("分组 \(group)") }
        return parts.isEmpty ? "未运行" : parts.joined(separator: " · ")
    }

    // MARK: - Restart advisory (CFG-5 / WIN-4: "需重启生效")

    /// Two distinct moments this can apply to, both worth a heads-up in the config window
    /// itself rather than only after the fact in the status panel:
    /// - still editing, unsaved, and a field that only takes effect on restart (command/
    ///   directory/environment/log paths/stop signal/timeout — `Program.runtimeFieldsDiffer`)
    ///   already differs from what's live;
    /// - already saved, and `Supervisor` marked this program `needsRestart` because such a
    ///   field changed while it was running (design.md CFG-5).
    private var restartAdvisoryText: String? {
        guard program.kind == .service, isRunning, let snapshot else { return nil }
        if isDirty, Program.runtimeFieldsDiffer(snapshot.program, program) {
            return "运行时字段已修改，保存后需要重启才能生效"
        }
        if !isDirty, snapshot.needsRestart {
            return "配置已变更，重启后生效"
        }
        return nil
    }

    private func restartAdvisory(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(text).font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            Button("立即重启", action: onRestartNow)
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
        }
        .foregroundStyle(StatusStyle.transitioning)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(StatusStyle.transitioning.opacity(0.1))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if isDirty {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                Text(isNew ? "尚未保存" : "有未保存的更改")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("撤销", action: onRevert)
                .disabled(!isDirty)
                .keyboardShortcut(.cancelAction)
            if isRunning {
                Button("保存并重启", action: onSaveAndRestart)
            }
            Button("保存", action: onSave)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    static func uptime(since date: Date) -> String {
        let seconds = Int(max(0, Date().timeIntervalSince(date)))
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "\(minutes) 分" }
        return "\(seconds) 秒"
    }
}

private struct KindBadge: View {
    let kind: ProgramKind

    var body: some View {
        Text(kind == .service ? "服务" : "一次性命令")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

private struct StatusPill: View {
    let snap: ProgramSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(snap.statusText).font(.callout)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    /// Delegates to `StatusStyle`, the single place that maps state → colour/label/symbol, so
    /// this pill can never quietly drift from what the status panel shows for the same state.
    private var color: Color { StatusStyle.presentation(for: snap).color }
}
