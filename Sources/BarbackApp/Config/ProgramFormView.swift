import SwiftUI
import BarbackCore

/// The detail pane: a fixed identity header, a segmented tab bar, and a sticky commit bar.
/// Splitting the form into three tabs — 常规 / 生命周期 / 日志 — keeps every page to roughly
/// one screen instead of the two-to-three-screen scroll the single stacked form produced
/// (design.md §6.5, CFG-3).
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
    let onShowLog: () -> Void
    let onShowHistory: () -> Void

    @State private var tab: FormTab = .general

    private var index: FieldErrorIndex { FieldErrorIndex(errors) }
    private var tabs: [FormTab] { FormTab.tabs(for: program.kind) }
    private var isRunning: Bool { snapshot?.isActive ?? false }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            content
            Divider()
            footer
        }
        .onChange(of: program.id) { _ in tab = .general }
        .onAppear { if !tabs.contains(tab) { tab = .general } }
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

    // MARK: - Tabs

    private var tabBar: some View {
        Picker("", selection: $tab) {
            ForEach(tabs) { item in
                Text(index.hasError(in: item) ? "\(item.title) ⚠︎" : item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .general:
            GeneralTab(program: $program, index: index, existingGroups: existingGroups)
        case .startup:
            StartupTab(program: $program, index: index)
        case .execution:
            ExecutionTab(program: $program, index: index)
        case .log:
            LogTab(program: $program)
        }
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

    private var color: Color {
        if let state = snap.serviceState {
            switch state {
            case .running: return .green
            case .starting, .backoff, .stopping: return .orange
            case .fatal: return .red
            case .stopped, .exited: return .secondary
            }
        }
        switch snap.oneshotState {
        case .running: return .accentColor
        case .failed, .timeout: return .red
        case .succeeded: return .green
        default: return .secondary
        }
    }
}
