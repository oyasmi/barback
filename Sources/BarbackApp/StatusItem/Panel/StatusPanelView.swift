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

    private let panelWidth: CGFloat = 420
    private let maxListHeight: CGFloat = 520

    private var snapshot: SupervisorSnapshot { appState.snapshot }
    private var services: [ProgramSnapshot] { model.visiblePrograms(kind: .service) }
    private var oneshots: [ProgramSnapshot] { model.visiblePrograms(kind: .oneshot) }

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
                SummaryChip(count: snapshot.runningCount, label: "运行中",
                            color: StatusStyle.running, symbol: "circle.fill")
                SummaryChip(count: snapshot.stoppedCount, label: "已停止",
                            color: StatusStyle.neutral, symbol: "circle")
                if snapshot.fatalCount > 0 {
                    SummaryChip(count: snapshot.fatalCount, label: "失败",
                                color: StatusStyle.failure, symbol: "exclamationmark.triangle.fill")
                }
                if snapshot.oneshotRunningCount > 0 {
                    SummaryChip(count: snapshot.oneshotRunningCount, label: "执行中",
                                color: StatusStyle.active, symbol: "circle.dotted")
                }
                Spacer(minLength: 4)
                GlyphButton(systemImage: "gearshape", help: "打开配置窗口 (⌘,)") { model.openConfig() }
                    .keyboardShortcut(",", modifiers: .command)
            }

            if snapshot.recoveredCount > 0 {
                noticeStrip(
                    "上次异常退出，已接管 \(snapshot.recoveredCount) 个仍在运行的进程",
                    color: StatusStyle.transitioning
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

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索程序", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !model.searchText.isEmpty {
                GlyphButton(systemImage: "xmark.circle.fill", help: "清除") { model.searchText = "" }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private func noticeStrip(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.1)))
    }

    // MARK: - List

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                if services.isEmpty && oneshots.isEmpty {
                    noMatches
                }
                if !services.isEmpty {
                    sectionHeader(title: "服务", count: services.count)
                    ForEach(serviceGroups, id: \.title) { group in
                        if serviceGroups.count > 1 {
                            groupHeader(group.title, count: group.items.count)
                        }
                        ForEach(group.items) { row(for: $0) }
                    }
                }
                if !oneshots.isEmpty {
                    sectionHeader(title: "一次性命令", count: oneshots.count)
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
    }

    private func row(for snap: ProgramSnapshot) -> some View {
        ProgramRowView(snap: snap, model: model)
            .id(snap.id)
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .padding(.bottom, 1)
    }

    private func groupHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.quaternary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .padding(.top, 3)
    }

    private struct ServiceGroup {
        let title: String
        let items: [ProgramSnapshot]
    }

    /// Services are only broken out by group once more than one group is actually in use —
    /// otherwise the headers are pure noise.
    private var serviceGroups: [ServiceGroup] {
        var order: [String] = []
        var buckets: [String: [ProgramSnapshot]] = [:]
        for snap in services {
            let key = snap.program.groupName?.isEmpty == false ? snap.program.groupName! : "未分组"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(snap)
        }
        guard order.count > 1 else { return [ServiceGroup(title: "服务", items: services)] }
        return order.map { ServiceGroup(title: $0, items: buckets[$0] ?? []) }
    }

    private var noMatches: some View {
        Text("没有匹配「\(model.searchText)」的程序")
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

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                DrawerButton(title: "全部启动", systemImage: "play.fill",
                             tint: StatusStyle.running, isEnabled: model.canStartAll) {
                    model.startAll()
                }
                DrawerButton(title: "全部停止", systemImage: "stop.fill",
                             tint: StatusStyle.failure, isEnabled: model.canStopAll) {
                    model.stopAll()
                }
                DrawerButton(title: "全部重启", systemImage: "arrow.clockwise",
                             isEnabled: model.hasServices) {
                    model.restartAll()
                }
            }

            HStack(spacing: 4) {
                if let toast = model.toast {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(StatusStyle.running)
                    Text(toast)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("右键状态栏图标可打开应用菜单")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                Text("Barback \(Self.version)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
