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
    private var isSelected: Bool { model.selectedId == snap.id }
    private var style: StatusStyle.Presentation { StatusStyle.presentation(for: snap) }
    /// Hovering, keyboard selection or an open drawer reveals the inline actions.
    private var showsSecondaryActions: Bool { isHovering || isSelected || isExpanded }
    private var isService: Bool { snap.program.kind == .service }
    private var serviceState: ServiceState { snap.serviceState ?? .stopped }

    private var isCompact: Bool { Preferences.menuDensity == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            summary
            if serviceState == .fatal {
                alertStrip(
                    text: fatalStripText,
                    color: StatusStyle.failure,
                    actionTitle: String(localized: "查看日志"),
                    action: { model.openLog(snap) }
                )
            }
            // A one-shot picks up new config on its next run by itself, so only a service
            // has something to act on here.
            if snap.needsRestart, isService {
                alertStrip(
                    text: String(localized: "配置已变更，重启后生效"),
                    color: StatusStyle.transitioning,
                    actionTitle: String(localized: "立即重启"),
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
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(snap.program.name)，\(style.label)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // The secondary buttons are invisible until hovered, which also hides them from
        // VoiceOver; the same actions are offered here instead.
        .accessibilityActions {
            Button(StatusStyle.primaryAction(for: snap).title) { model.performPrimary(snap) }
            if isService, serviceState.isActive {
                Button(String(localized: "重启")) { model.restart(snap) }
            }
            Button(isService ? String(localized: "查看日志") : String(localized: "查看本次输出")) { model.openLog(snap) }
            if !isService {
                Button(String(localized: "执行历史")) { model.openHistory(snap) }
            }
            Button(isExpanded ? String(localized: "收起详情") : String(localized: "展开详情")) { model.toggleExpanded(snap.id) }
        }
    }

    /// The part of the row a click expands. The drawer is deliberately outside it: a click
    /// that lands between two facts — or one meant to place a caret in a selectable path —
    /// used to fold the whole drawer away.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleRow
            if !isCompact || isExpanded {
                detailRow
            }
            if serviceState == .backoff {
                backoffBar
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Clicking a row also moves the keyboard cursor there, so ↑/↓ continues from
            // where the pointer left off instead of jumping back to the top.
            model.selectedId = snap.id
            model.toggleExpanded(snap.id)
        }
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
                .help(snap.program.name)
            // The state's wording leads the detail line below, which leaves the title row its
            // width for the name. Compact density has no detail line, so there the badge stays.
            // Disabled is an attribute, never a replacement for the live state.
            if !snap.program.enabled {
                if isCompact {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("已停用").accessibilityLabel("已停用")
                } else {
                    MetaTag(text: String(localized: "已停用"))
                }
            }
            if isCompact {
                StateBadge(text: style.label, color: style.color, quiet: style.isQuiet)
            }
            Spacer(minLength: 4)
            // The name is the only thing allowed to shrink here: an action whose label has
            // been truncated to "启…" is worse than a name truncated in the middle.
            actionCluster
                .fixedSize()
                .layoutPriority(1)
        }
    }

    private var statusIcon: some View {
        StatusGlyph(style: style)
    }

    private var actionCluster: some View {
        HStack(spacing: 2) {
            primaryButton
            secondaryActions
                // Reserve their width so the primary stays put as the pointer approaches.
                .opacity(showsSecondaryActions ? 1 : 0)
                .allowsHitTesting(showsSecondaryActions)
                .accessibilityHidden(!showsSecondaryActions)
                .animation(.easeOut(duration: 0.12), value: showsSecondaryActions)
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        HStack(spacing: 2) {
            if isService {
                GlyphButton(systemImage: "arrow.clockwise", help: String(localized: "重启 (⌘R)"), isEnabled: serviceState.isActive) {
                    model.restart(snap)
                }
                GlyphButton(systemImage: "doc.plaintext", help: String(localized: "查看日志 (⌘L)")) { model.openLog(snap) }
            } else {
                GlyphButton(systemImage: "doc.plaintext", help: String(localized: "查看本次输出 (⌘L)"), isEnabled: snap.lastRun != nil) { model.openLog(snap) }
                GlyphButton(systemImage: "clock.arrow.circlepath", help: String(localized: "执行历史")) { model.openHistory(snap) }
            }
            GlyphButton(systemImage: isExpanded ? "chevron.up" : "chevron.down",
                        help: isExpanded ? String(localized: "收起详情 (↩)") : String(localized: "展开详情 (↩)")) {
                model.toggleExpanded(snap.id)
            }
        }
    }

    /// Label, tint and behaviour all come from `StatusStyle.primaryAction`, which the ⌘↩
    /// keyboard path uses too. Neutral at rest unless urgent; it takes its colour as the row
    /// is approached, so the consequence is visible right before the click.
    private var primaryButton: some View {
        let action = StatusStyle.primaryAction(for: snap)
        return PillButton(title: action.title, systemImage: action.symbol, tint: action.tint,
                          isEmphasized: action.isUrgent || showsSecondaryActions,
                          help: String(localized: "\(action.title) (⌘↩)")) {
            model.performPrimary(snap)
        }
    }

    // MARK: - Detail line

    private var detailRow: some View {
        HStack(spacing: 0) {
            detailText
                .font(.system(size: 11))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 22)
        .help(detailText)
    }

    /// "运行中 · up 2d3h · CPU 累计 12.3s · 48.0 MB": the state's word first, in its colour unless
    /// it is a quiet one, then the figures. Compact density keeps the word in the title row's
    /// badge instead. Disabled configuration is an independent attribute.
    private var detailText: Text {
        let rest = isService ? serviceDetail() : oneshotDetail()
        let leadsWithState = !isCompact
        guard leadsWithState else { return Text(rest).foregroundColor(.secondary) }
        let lead = Text(style.label)
            .fontWeight(.medium)
            .foregroundColor(style.isQuiet ? .secondary : style.color)
        guard !rest.isEmpty else { return lead }
        return lead + Text(" · " + rest).foregroundColor(.secondary)
    }

    private func serviceDetail() -> String {
        var parts: [String] = []
        switch serviceState {
        // PID is left to the drawer, where it can be copied: as the first figure on every line
        // it was the least-read thing in the most-read place.
        case .running, .starting, .stopping:
            if let startedAt = snap.startedAt {
                parts.append("up \(StatusStyle.uptimeShort(model.now.timeIntervalSince(startedAt)))")
            }
            if let sample = model.sample(for: snap) {
                parts.append(String(localized: "CPU 累计 \(StatusStyle.cpuTime(sample.totalCPUSeconds))"))
                parts.append(StatusStyle.memory(sample.rssBytes))
            }
            if serviceState == .stopping { parts.append(String(localized: "等待退出")) }
        case .backoff:
            if let remaining = model.backoffRemaining(for: snap) {
                parts.append(String(localized: "\(Int(remaining.rounded())) 秒后重试"))
            }
            parts.append(contentsOf: lastExitParts())
        case .fatal:
            parts.append(String(localized: "已重试 \(snap.retryCount) 次"))
            parts.append(contentsOf: lastExitParts())
        case .stopped, .exited:
            let exit = lastExitParts()
            parts = exit.isEmpty ? [String(localized: "未曾启动")] : exit
        }
        if snap.retryCount > 0, serviceState == .running {
            parts.append(String(localized: "已重启 \(snap.retryCount) 次"))
        }
        return parts.joined(separator: " · ")
    }

    private func lastExitParts() -> [String] {
        guard let run = snap.lastRun, let endedAt = run.endedAt else { return [] }
        var parts = [String(localized: "上次退出 \(StatusStyle.relative(endedAt, now: model.now))")]
        if let exit = exitSummary { parts.append(exit) }
        return parts
    }

    /// "退出码 127" / "信号 9" from the last run, or nothing.
    private var exitSummary: String? {
        guard let run = snap.lastRun, run.endedAt != nil else { return nil }
        if let code = run.exitCode { return String(localized: "退出码 \(code)") }
        if let signal = run.termSignal { return String(localized: "信号 \(signal)") }
        return nil
    }

    private func oneshotDetail() -> String {
        var parts: [String] = []
        if snap.oneshotState == .running {
            if let run = snap.lastRun {
                parts.append("run \(StatusStyle.uptimeShort(model.now.timeIntervalSince(run.startedAt)))")
            }
            if let sample = model.sample(for: snap) {
                parts.append("CPU \(StatusStyle.cpu(sample.cpuPercent))")
                parts.append(StatusStyle.memory(sample.rssBytes))
            }
        } else if let run = snap.lastRun {
            parts.append(String(localized: "上次 \(StatusStyle.relative(run.endedAt ?? run.startedAt, now: model.now))"))
            if let duration = run.duration { parts.append(String(localized: "耗时 \(StatusStyle.runDuration(duration))")) }
            if let code = run.exitCode, code != 0 { parts.append(String(localized: "退出码 \(code)")) }
            parts.append(String(localized: "共 \(snap.runCount) 次"))
        } else {
            parts.append(String(localized: "尚未执行过"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Strips

    /// Why there is nothing more to wait for, with the exit that ended it — compact density
    /// has no detail line to carry the code, and this is the line someone reads first.
    private var fatalStripText: String {
        let text = String(localized: "自动重试已停止")
        guard let exit = exitSummary else { return text }
        return text + " · " + exit
    }

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
            factLine(label: String(localized: "命令"), value: snap.program.command, monospaced: true) {
                model.copy(snap.program.command, label: String(localized: "命令"))
            }
            if let directory = snap.program.directory {
                factLine(label: String(localized: "目录"), value: directory, monospaced: true, copy: nil)
            }
            factLine(label: String(localized: "日志"), value: ProgramLogPath.resolve(for: snap), monospaced: true, copy: nil)
            facts
            actions
        }
        .padding(.leading, 22)
        .padding(.top, 1)
    }

    /// Wide enough for the longest fact label in the active localization: two CJK characters, or
    /// "Directory" in English — a fixed 26 pt truncated every English label.
    private static let factLabelWidth: CGFloat = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? 26 : 56

    private func factLine(label: String, value: String, monospaced: Bool, copy: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .frame(width: Self.factLabelWidth, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 2)
            if let copy {
                GlyphButton(systemImage: "doc.on.doc", help: String(localized: "复制"), action: copy)
            }
        }
    }

    private var facts: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 3) {
            ForEach(factPairs, id: \.0) { pair in
                HStack(spacing: 4) {
                    Text(pair.0)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Text(pair.1)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
    }

    private var factPairs: [(String, String)] {
        var pairs: [(String, String)] = []
        if let group = snap.program.groupName, !group.isEmpty { pairs.append((String(localized: "分组"), group)) }
        if isService {
            if let startedAt = snap.startedAt, serviceState.isActive {
                pairs.append((String(localized: "启动于"), StatusStyle.timestamp(startedAt)))
            }
            pairs.append((String(localized: "自动启动"), snap.program.autostart ? String(localized: "开") : String(localized: "关")))
            pairs.append((String(localized: "自动重启"), autorestartText))
            pairs.append((String(localized: "停止信号"), "SIG\(snap.program.stopSignal)"))
        } else {
            pairs.append((String(localized: "执行次数"), String(localized: "\(snap.runCount) 次")))
            if snap.program.timeoutSeconds > 0 {
                pairs.append((String(localized: "超时时间"), String(localized: "\(snap.program.timeoutSeconds) 秒")))
            }
            if snap.program.confirmBeforeRun { pairs.append((String(localized: "运行前"), String(localized: "需确认"))) }
        }
        return pairs
    }

    private var autorestartText: String {
        switch snap.program.autorestart {
        case .never: return String(localized: "从不")
        case .unexpected: return String(localized: "非预期退出")
        case .always: return String(localized: "总是")
        }
    }

    private var actions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 5)], spacing: 5) {
            DrawerButton(title: String(localized: "在 Finder 中显示"), systemImage: "folder") { model.revealLog(snap) }
            if let pid = snap.pid {
                DrawerButton(title: String(localized: "复制 PID \(pid)"), systemImage: "number") {
                    model.copy("\(pid)", label: "PID")
                }
            }
            // Moved off the FATAL strip, whose one button is now 查看日志: the log answers the
            // question a failure raises, and clearing the state without starting is the rarer
            // step.
            if serviceState == .fatal {
                DrawerButton(title: String(localized: "清除状态"), systemImage: "xmark.circle") { model.clearFatal(snap) }
            }
            // 强制终止 is deliberately absent here: the state machine only accepts a kill
            // while a stop is in flight, and that case is already the row's primary button.
            DrawerButton(title: String(localized: "编辑配置…"), systemImage: "slider.horizontal.3") {
                model.openConfig(selecting: snap.id)
            }
        }
    }

    // MARK: - Chrome

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(isExpanded || isSelected ? 0.06 : (isHovering ? 0.045 : 0)))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            }
    }

    private var strokeColor: Color {
        if isSelected { return Color.accentColor.opacity(0.55) }
        return style.color.opacity(isExpanded ? 0.2 : 0)
    }

    /// Services have a scannable state spine. Commands use their spinner/result glyph only:
    /// a green bar on a completed command would read as a still-running service.
    @ViewBuilder
    private var accentBar: some View {
        if isService {
            Capsule()
                .fill(style.color.opacity(snap.isActive ? (style.isQuiet ? 0.45 : 0.8) : 0.3))
                .frame(width: 3, height: 18)
                .padding(.leading, 1)
                .padding(.top, 8)
        }
    }
}
