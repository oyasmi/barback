import SwiftUI
import BarbackCore

/// Stable identity, a task-oriented editor, and one commit bar for save/restart actions.
struct ProgramFormView: View {
    @Binding var program: Program
    @Binding var environmentText: String
    @Binding var expandedSections: [Int64: Set<String>]
    @Binding var scrollAnchors: [Int64: String]
    let environmentErrors: [String]
    let validationRequest: Int
    let isSaving: Bool
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
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    private var index: FieldErrorIndex { FieldErrorIndex(errors, environmentErrors: environmentErrors, program: program) }
    private var needsRestart: Bool {
        guard program.kind == .service, let snapshot, snapshot.isActive else { return false }
        return snapshot.needsRestart || (isDirty && Program.runtimeFieldsDiffer(snapshot.program, program))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let text = restartAdvisoryText {
                restartAdvisory(text: text)
            }
            Divider()
            ProgramFormBody(
                program: $program,
                environmentText: $environmentText,
                expandedSections: $expandedSections,
                scrollAnchors: $scrollAnchors,
                index: index,
                validationRequest: validationRequest,
                existingGroups: existingGroups
            )
            Divider()
            footer
        }
        .frame(minWidth: 540)
        .disabled(isSaving)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Text(program.name.isEmpty ? "未命名" : program.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .help(program.name)
                Spacer(minLength: 8)
                if !isNew {
                    Button("日志", action: onShowLog)
                    if program.kind == .oneshot { Button("历史", action: onShowHistory) }
                    Menu {
                        Button("复制程序", action: onDuplicate)
                            .keyboardShortcut("d", modifiers: .command)
                        Button("删除程序…", role: .destructive, action: onDelete)
                            .keyboardShortcut(.delete, modifiers: .command)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("程序操作")
                    .accessibilityLabel("程序操作")
                }
            }
            HStack(spacing: 8) {
                Text(program.kind == .service ? "服务" : "一次性命令")
                if let snapshot { StatusPill(snap: snapshot) }
                Text(subtitle).lineLimit(1).help(subtitle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
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
        return parts.joined(separator: " · ")
    }

    // MARK: - Save / apply feedback

    private var restartAdvisoryText: String? {
        guard needsRestart else { return nil }
        return isDirty ? "这些更改需要重启后生效。可先保存，或保存并重启。" : "配置已保存，重启后生效。"
    }

    private func restartAdvisory(text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(0.06))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(commitStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if index.count > 0 {
                    Label("有 \(index.count) 项需要修正", systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            if isDirty {
                Button("放弃更改", action: onRevert)
                    .keyboardShortcut(.cancelAction)
            }
            if needsRestart {
                if isDirty {
                    Button("保存并重启", action: onSaveAndRestart)
                } else {
                    Button("立即重启", action: onRestartNow)
                }
            }
            Button("保存", action: onSave)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty)
        }
        .controlSize(.small)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var commitStatus: String {
        if isSaving { return "正在保存…" }
        if isNew { return "尚未保存" }
        if isDirty { return "有未保存的更改" }
        return needsRestart ? "已保存 · 待重启" : "已保存"
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

private struct StatusPill: View {
    let snap: ProgramSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(snap.statusText).font(.caption)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    /// Delegates to `StatusStyle`, the single place that maps state → colour/label/symbol, so
    /// this pill can never quietly drift from what the status panel shows for the same state.
    private var color: Color { StatusStyle.presentation(for: snap).color }
}
