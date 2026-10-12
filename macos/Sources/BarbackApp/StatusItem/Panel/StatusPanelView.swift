import SwiftUI
import BarbackCore

/// The left-click panel: everything you manage a process with, in one place.
///
/// This replaces the old `NSMenu`, which could only offer a name and a status string per
/// row and hid start/stop behind a submenu. A panel buys live metrics, colour that means
/// something, and one-click actions — at the cost of having to draw it ourselves.
struct StatusPanelView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: StatusPanelModel

    @State private var contentHeight: CGFloat = 0
    /// The search field takes focus as soon as it appears, so typing works the moment the
    /// panel opens instead of silently going nowhere (BAR-10).
    @FocusState private var searchFocused: Bool

    private let panelWidth: CGFloat = 420
    private let maxListHeight: CGFloat = 520

    private var snapshot: SupervisorSnapshot { appState.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            header
            separator
            if snapshot.programs.isEmpty {
                emptyState
            } else {
                list
                separator
                footer
            }
        }
        .frame(width: panelWidth)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // All five chips with their words don't fit beside the two buttons; when they
                // all show up at once, the words go and dot + number carry it (the label stays
                // in the tooltip and for VoiceOver).
                ViewThatFits(in: .horizontal) {
                    chips(showsLabels: true)
                    chips(showsLabels: false)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                GlyphButton(systemImage: "gearshape", help: String(localized: "打开配置窗口 (⌘,)")) { model.openConfig() }
                    .keyboardShortcut(",", modifiers: .command)
                // Everything the right-click menu offers, for the many people who never think
                // to right-click a menu-bar icon.
                GlyphButton(systemImage: "ellipsis.circle", help: String(localized: "更多")) { model.showAppMenu() }
            }

            if snapshot.recoveredCount > 0 {
                noticeStrip(
                    String(localized: "上次异常退出，已接管 \(snapshot.recoveredCount) 个仍在运行的进程"),
                    color: StatusStyle.transitioning,
                    onDismiss: { model.dismissRecoveryNotice() }
                )
            }

            if model.isSearchable {
                searchField
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 9)
        .background(.bar)
    }

    private func chips(showsLabels: Bool) -> some View {
        HStack(spacing: 6) {
            chip(.running, label: String(localized: "运行中"), color: StatusStyle.running, symbol: "circle.fill",
                 showsLabel: showsLabels, always: true)
            chip(.stopped, label: String(localized: "已停止"), color: StatusStyle.neutral, symbol: "circle",
                 showsLabel: showsLabels, always: true)
            chip(.transitioning, label: String(localized: "过渡中"), color: StatusStyle.transitioning,
                 symbol: "circle.bottomhalf.filled", showsLabel: showsLabels)
            chip(.fatal, label: String(localized: "失败"), color: StatusStyle.failure,
                 symbol: "exclamationmark.triangle.fill", showsLabel: showsLabels)
            chip(.oneshotRunning, label: String(localized: "执行中"), color: StatusStyle.active,
                 symbol: "circle.dotted", showsLabel: showsLabels)
        }
        .fixedSize()
    }

    /// `always` keeps the two baseline chips (运行中 / 已停止) on screen at zero, so the header
    /// doesn't reflow every time the last service stops; the exceptional ones come and go.
    @ViewBuilder
    private func chip(_ filter: PanelFilter, label: String, color: Color, symbol: String,
                      showsLabel: Bool, always: Bool = false) -> some View {
        let count = model.count(filter)
        if always || count > 0 {
            SummaryChip(count: count, label: label, color: color, symbol: symbol, showsLabel: showsLabel,
                        isSelected: model.filter == filter,
                        isDimmed: model.filter != nil && model.filter != filter) {
                model.toggleFilter(filter)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索程序", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onAppear { searchFocused = true }
            if !model.searchText.isEmpty {
                GlyphButton(systemImage: "xmark.circle.fill", help: String(localized: "清除")) { model.searchText = "" }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    /// design.md §3.7 step 7 says this notice appears *once*. It has no natural expiry —
    /// `recoveredCount` is fixed for the life of the process — so without a way to dismiss it
    /// the strip reappeared on every single panel open until the app was quit.
    private func noticeStrip(_ text: String, color: Color, onDismiss: (() -> Void)? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 0)
            if let onDismiss {
                GlyphButton(systemImage: "xmark", help: String(localized: "知道了"), tint: color, action: onDismiss)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.1)))
    }

    // MARK: - List

    private var list: some View {
        // Computed once per rebuild: each of these filters the whole snapshot, and the body
        // below would otherwise re-derive them for every row it draws.
        let attention = model.attentionPrograms
        let groups = model.serviceGroups
        let calmCount = groups.reduce(0) { $0 + $1.items.count }
        let oneshots = model.visiblePrograms(kind: .oneshot)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if attention.isEmpty && groups.isEmpty && oneshots.isEmpty {
                        noMatches
                    }
                    if !attention.isEmpty {
                        sectionHeader(title: String(localized: "需要处理"), count: attention.count,
                                      tint: attention.contains(where: { $0.serviceState == .fatal })
                                          ? StatusStyle.failure : StatusStyle.transitioning)
                        ForEach(attention) { row(for: $0) }
                    }
                    if !groups.isEmpty {
                        sectionHeader(title: String(localized: "服务"), count: calmCount)
                        ForEach(groups, id: \.title) { group in
                            if groups.count > 1 {
                                groupHeader(group.title, count: group.items.count)
                            }
                            ForEach(group.items) { row(for: $0) }
                        }
                    }
                    if !oneshots.isEmpty {
                        sectionHeader(title: String(localized: "一次性命令"), count: oneshots.count)
                        ForEach(oneshots) { row(for: $0) }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .measuringHeight()
            }
            // Keep the scroller on screen once the list overflows: in a popover there is no
            // window edge to hint that something is below the fold.
            .scrollIndicators(contentHeight > maxListHeight ? .visible : .hidden)
            .frame(height: min(max(contentHeight, 44), maxListHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            // ↑/↓ can walk past the fold, and a cursor you can't see is worse than no cursor.
            .onChange(of: model.selectedId) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func row(for snap: ProgramSnapshot) -> some View {
        ProgramRowView(snap: snap, model: model)
            .id(snap.id)
    }

    private func sectionHeader(title: String, count: Int, tint: Color? = nil) -> some View {
        HStack(spacing: 5) {
            if tint != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint ?? Color.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .padding(.bottom, 1)
    }

    private func groupHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .padding(.top, 3)
    }

    @ViewBuilder
    private var noMatches: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        Group {
            if query.isEmpty {
                Text("没有符合筛选的程序")
            } else {
                Text("没有匹配「\(query)」的程序")
            }
        }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 46, height: 46)
                Image(systemName: "wineglass")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            Text("还没有托管任何程序")
                .font(.system(size: 13, weight: .semibold))
            Text("在配置窗口新建服务或一次性命令，\n也可以从 supervisor 配置粘贴导入。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            Button("打开配置窗口") { model.openConfig() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 16)
    }

    // MARK: - Footer

    /// One line: what just happened (or what is running) on the left, the bulk action on the
    /// right. The old second line — a keyboard cheat sheet and the version number — was read
    /// once and then just took up room; the shortcuts now live in each control's tooltip.
    private var footer: some View {
        HStack(spacing: 8) {
            statusLine
                .frame(maxWidth: .infinity, alignment: .leading)
            bulkActions
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .background(.bar)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let toast = model.toast {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(StatusStyle.running)
                Text(toast)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if let event = model.recentProblem {
            Button { model.openEvents() } label: {
                HStack(spacing: 4) {
                    Image(systemName: event.level == .error ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(event.level == .error ? StatusStyle.failure : StatusStyle.transitioning)
                    Text(model.describe(event))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "打开事件日志"))
        } else if let summary = model.resourceSummary {
            Text(summary)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// One visible bulk button that follows the situation, with the rest one chevron away.
    private var bulkActions: some View {
        HStack(spacing: 2) {
            if model.prefersStartAll {
                DrawerButton(title: String(localized: "全部启动"), systemImage: "play.fill",
                             tint: StatusStyle.running, isEnabled: model.canStartAll) {
                    model.startAll()
                }
                .fixedSize()
            } else {
                DrawerButton(title: String(localized: "全部停止"), systemImage: "stop.fill",
                             tint: StatusStyle.failure) {
                    model.stopAll()
                }
                .fixedSize()
            }
            MenuGlyph(systemImage: "chevron.down", help: String(localized: "更多批量操作")) {
                if !model.prefersStartAll {
                    Button("全部启动") { model.startAll() }
                        .disabled(!model.canStartAll)
                }
                if model.prefersStartAll {
                    Button("全部停止…") { model.stopAll() }
                        .disabled(!model.canStopAll)
                }
                Button("全部重启…") { model.restartAll() }
                    .disabled(!model.canRestartAll)
            }
        }
    }
}
