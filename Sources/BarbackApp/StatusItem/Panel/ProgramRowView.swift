import SwiftUI
import BarbackCore

/// One managed program in the status panel.
///
/// The whole point of the redesign: every action a person reaches for daily is *on* the
/// row — start/stop, restart, logs — instead of one hover-and-wait submenu away. The rest
/// (command, paths, force kill, edit) lives in a drawer the row expands into, so the
/// panel never has to hand off to another window just to answer "what is this thing".
struct ProgramRowView: View {
    let snap: ProgramSnapshot
    @ObservedObject var model: StatusPanelModel

    @State private var isHovering = false

    private var isExpanded: Bool { model.expandedId == snap.id }
    private var style: StatusStyle.Presentation { StatusStyle.presentation(for: snap) }
    private var isService: Bool { snap.program.kind == .service }
    private var serviceState: ServiceState { snap.serviceState ?? .stopped }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleRow
            if Preferences.menuDensity == .normal || isExpanded {
                detailRow
            }
            if serviceState == .backoff {
                backoffBar
            }
            if serviceState == .fatal {
                alertStrip(
                    text: "自动重试已停止，需要人工处理",
                    color: StatusStyle.failure,
                    actionTitle: "清除状态",
                    action: { model.clearFatal(snap) }
                )
            }
            // A one-shot picks up new config on its next run by itself, so only a service
            // has something to act on here.
            if snap.needsRestart, isService {
                alertStrip(
                    text: "配置已变更，重启后生效",
                    color: StatusStyle.transitioning,
                    actionTitle: "立即重启",
                    action: { model.restart(snap) }
                )
            }
            if isExpanded {
                drawer
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(rowBackground)
        .overlay(alignment: .topLeading) { accentBar }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { model.toggleExpanded(snap.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(snap.program.name)，\(style.label)")
    }

    // MARK: - Title row

    private var titleRow: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(snap.program.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(snap.program.enabled ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            // A disabled program is always stopped, so the state badge would only repeat what
            // 已停用 already says — and the row needs that width for its actions.
            if snap.program.enabled {
                StateBadge(text: style.label, color: style.color)
            } else {
                MetaTag(text: "已停用")
            }
            Spacer(minLength: 4)
            // The name is the only thing allowed to shrink here: an action whose label has
            // been truncated to "启…" is worse than a name truncated in the middle.
            actionCluster
                .fixedSize()
                .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if style.isBusy {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: style.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style.color)
                .frame(width: 14, height: 14)
        }
    }

    @ViewBuilder
    private var actionCluster: some View {
        HStack(spacing: 2) {
            primaryButton
            if isService {
                GlyphButton(systemImage: "arrow.clockwise", help: "重启", isEnabled: serviceState.isActive) {
                    model.restart(snap)
                }
                GlyphButton(systemImage: "doc.plaintext", help: "查看日志") { model.openLog(snap) }
            } else {
                GlyphButton(systemImage: "doc.plaintext", help: "查看本次输出") { model.openLog(snap) }
                GlyphButton(systemImage: "clock.arrow.circlepath", help: "执行历史") { model.openHistory(snap) }
            }
            GlyphButton(systemImage: isExpanded ? "chevron.up" : "chevron.down",
                        help: isExpanded ? "收起详情" : "展开详情") {
                model.toggleExpanded(snap.id)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if isService {
            // A disabled-but-inactive service showed a perfectly clickable "启动" here even
            // though the row's own badge says 已停用 and "停用" is documented to mean "won't
            // start on its own" — the only consistent reading is that starting it manually
            // first requires turning it back on (design.md §6.3, ex-F06). A service disabled
            // while still running keeps its normal stop/restart controls; disabling doesn't
            // touch anything already active.
            if !snap.program.enabled, !serviceState.isActive {
                PillButton(title: "启用", systemImage: "checkmark.circle", tint: StatusStyle.running) {
                    model.enable(snap)
                }
            } else {
                serviceButton
            }
        } else if snap.oneshotState == .running {
            PillButton(title: "中止", systemImage: "stop.fill", tint: StatusStyle.failure) {
                model.cancelOneshot(snap)
            }
        } else {
            PillButton(title: "运行", systemImage: "play.fill", tint: StatusStyle.active) {
                model.runOneshot(snap)
            }
        }
    }

    @ViewBuilder
    private var serviceButton: some View {
        switch serviceState {
        case .stopping:
            // TERM has been sent and we are waiting it out; the only useful escalation
            // here is SIGKILL, so that is what the row offers.
            PillButton(title: "强制终止", systemImage: "bolt.fill", tint: StatusStyle.failure) {
                model.forceKill(snap)
            }
        case .running, .starting, .backoff:
            PillButton(title: "停止", systemImage: "stop.fill", tint: StatusStyle.failure) {
                model.stop(snap)
            }
        case .stopped, .exited, .fatal:
            PillButton(title: "启动", systemImage: "play.fill", tint: StatusStyle.running) {
                model.start(snap)
            }
        }
    }

    // MARK: - Detail line

    private var detailRow: some View {
        HStack(spacing: 0) {
            Text(detailText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 22)
    }

    private var detailText: String {
        isService ? serviceDetail() : oneshotDetail()
    }

    private func serviceDetail() -> String {
        var parts: [String] = []
        switch serviceState {
        case .running, .starting, .stopping:
            if let pid = snap.pid { parts.append("PID \(pid)") }
            if let startedAt = snap.startedAt {
                parts.append("up \(StatusStyle.uptimeShort(model.now.timeIntervalSince(startedAt)))")
            }
            if let sample = model.sample(for: snap) {
                parts.append("CPU \(StatusStyle.cpu(sample.cpuPercent))")
                parts.append(StatusStyle.memory(sample.rssBytes))
            }
            if serviceState == .stopping { parts.append("等待退出") }
        case .backoff:
            if let remaining = model.backoffRemaining(for: snap) {
                parts.append("\(Int(remaining.rounded())) 秒后重试")
            }
            parts.append(contentsOf: lastExitParts())
        case .fatal:
            parts.append("已重试 \(snap.retryCount) 次")
            parts.append(contentsOf: lastExitParts())
        case .stopped, .exited:
            let exit = lastExitParts()
            parts = exit.isEmpty ? ["未曾启动"] : exit
        }
        if snap.retryCount > 0, serviceState == .running {
            parts.append("已重启 \(snap.retryCount) 次")
        }
        return parts.joined(separator: " · ")
    }

    private func lastExitParts() -> [String] {
        guard let run = snap.lastRun, let endedAt = run.endedAt else { return [] }
        var parts = ["上次退出 \(StatusStyle.timestamp(endedAt))"]
        if let code = run.exitCode {
            parts.append("退出码 \(code)")
        } else if let signal = run.termSignal {
            parts.append("信号 \(signal)")
        }
        return parts
    }

    private func oneshotDetail() -> String {
        var parts: [String] = []
        if snap.oneshotState == .running {
            if let pid = snap.pid { parts.append("PID \(pid)") }
            if let run = snap.lastRun {
                parts.append("run \(StatusStyle.uptimeShort(model.now.timeIntervalSince(run.startedAt)))")
            }
            if let sample = model.sample(for: snap) {
                parts.append("CPU \(StatusStyle.cpu(sample.cpuPercent))")
                parts.append(StatusStyle.memory(sample.rssBytes))
            }
        } else if let run = snap.lastRun {
            parts.append("上次 \(StatusStyle.timestamp(run.startedAt))")
            if let duration = run.duration { parts.append("耗时 \(StatusStyle.runDuration(duration))") }
            if let code = run.exitCode, code != 0 { parts.append("退出码 \(code)") }
            parts.append("共 \(snap.runCount) 次")
        } else {
            parts.append("尚未执行过")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Strips

    private var backoffBar: some View {
        HairlineProgress(fraction: model.backoffProgress(for: snap), color: StatusStyle.transitioning)
            .padding(.leading, 22)
            .padding(.trailing, 2)
    }

    private func alertStrip(text: String, color: Color, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.1)))
        .padding(.leading, 22)
    }

    // MARK: - Drawer

    private var drawer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().opacity(0.5)
            factLine(label: "命令", value: snap.program.command, monospaced: true) {
                model.copy(snap.program.command, label: "命令")
            }
            if let directory = snap.program.directory {
                factLine(label: "目录", value: directory, monospaced: true, copy: nil)
            }
            factLine(label: "日志", value: ProgramLogPath.resolve(for: snap), monospaced: true, copy: nil)
            facts
            actions
        }
        .padding(.leading, 22)
        .padding(.top, 1)
    }

    private func factLine(label: String, value: String, monospaced: Bool, copy: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 26, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 2)
            if let copy {
                GlyphButton(systemImage: "doc.on.doc", help: "复制", action: copy)
            }
        }
    }

    private var facts: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 3) {
            ForEach(factPairs, id: \.0) { pair in
                HStack(spacing: 4) {
                    Text(pair.0)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(pair.1)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
    }

    private var factPairs: [(String, String)] {
        var pairs: [(String, String)] = []
        if let group = snap.program.groupName, !group.isEmpty { pairs.append(("分组", group)) }
        if isService {
            if let startedAt = snap.startedAt, serviceState.isActive {
                pairs.append(("启动于", StatusStyle.timestamp(startedAt)))
            }
            pairs.append(("自动启动", snap.program.autostart ? "开" : "关"))
            pairs.append(("自动重启", autorestartText))
            pairs.append(("停止信号", "SIG\(snap.program.stopSignal)"))
        } else {
            pairs.append(("执行次数", "\(snap.runCount) 次"))
            if snap.program.timeoutSeconds > 0 {
                pairs.append(("超时", "\(snap.program.timeoutSeconds) 秒"))
            }
            if snap.program.confirmBeforeRun { pairs.append(("运行前", "需确认")) }
        }
        return pairs
    }

    private var autorestartText: String {
        switch snap.program.autorestart {
        case .never: return "从不"
        case .unexpected: return "非预期退出"
        case .always: return "总是"
        }
    }

    private var actions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 5)], spacing: 5) {
            if isService {
                DrawerButton(title: "在 Finder 中显示", systemImage: "folder") { model.revealLog(snap) }
                if let pid = snap.pid {
                    DrawerButton(title: "复制 PID \(pid)", systemImage: "number") {
                        model.copy("\(pid)", label: "PID")
                    }
                }
            } else {
                DrawerButton(title: "在 Finder 中显示", systemImage: "folder") { model.revealLog(snap) }
            }
            // 强制终止 is deliberately absent here: the state machine only accepts a kill
            // while a stop is in flight, and that case is already the row's primary button.
            DrawerButton(title: "编辑配置…", systemImage: "slider.horizontal.3") {
                model.openConfig(selecting: snap.id)
            }
        }
    }

    // MARK: - Chrome

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(isExpanded ? 0.06 : (isHovering ? 0.045 : 0)))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(style.color.opacity(isExpanded ? 0.2 : 0), lineWidth: 1)
            }
    }

    private var accentBar: some View {
        Capsule()
            .fill(style.color.opacity(snap.isActive ? 0.75 : 0.3))
            .frame(width: 3, height: 18)
            .padding(.leading, 1)
            .padding(.top, 8)
    }
}
