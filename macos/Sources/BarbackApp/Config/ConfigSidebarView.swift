import SwiftUI
import BarbackCore

/// The program list. Read-only status only — day-to-day start/stop stays in the status-bar
/// menu (design.md §6.5), so nothing here can accidentally control a running process.
struct ConfigSidebarView: View {
    @ObservedObject var model: ConfigWindowModel
    @ObservedObject var appState: AppState
    let onImport: () -> Void
    let onShowLog: (Int64) -> Void
    let onShowHistory: (Int64) -> Void

    private struct SidebarGroup: Identifiable {
        let id: String
        let title: String
        let items: [ProgramSnapshot]
    }

    var body: some View {
        VStack(spacing: 0) {
            collectionHeader
            Divider()
            List(selection: selectionBinding) {
                if model.isCreatingNew, let draft = model.draft {
                    Section("新建") {
                        DraftRow(program: draft)
                            .tag(ConfigWindowModel.newDraftId)
                    }
                }
                ForEach(groups) { group in
                    Section {
                        if canReorder {
                            ForEach(group.items) { row(for: $0) }
                                .onMove { source, destination in
                                    move(groupId: group.id, from: source, to: destination)
                                }
                        } else {
                            ForEach(group.items) { row(for: $0) }
                        }
                    } header: {
                        HStack {
                            Text(group.title)
                            Spacer()
                            Text("\(group.items.count)").foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if groups.isEmpty && !model.isCreatingNew {
                    emptyListHint
                }
            }
        }
    }

    private func row(for snap: ProgramSnapshot) -> some View {
        ProgramRow(snap: snap, isDirty: model.currentId == snap.id && model.isDirty)
            .tag(snap.id)
            .contextMenu {
                Button("查看日志…") { onShowLog(snap.id) }
                if snap.program.kind == .oneshot {
                    Button("执行历史…") { onShowHistory(snap.id) }
                }
                Divider()
                Button("复制") { model.attempt(.duplicate(snap.id)) }
                Button("删除…", role: .destructive) { model.requestDelete(id: snap.id) }
            }
    }

    @ViewBuilder private var emptyListHint: some View {
        if model.searchText.isEmpty {
            // The detail pane carries the full first-run state with its actions; this stays a hint.
            Text("还没有程序").foregroundStyle(.secondary)
        } else {
            ContentUnavailableView.search(text: model.searchText)
        }
    }

    private var collectionHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("程序").font(.headline)
                Spacer()
                Menu {
                    Button("新建服务") { model.attempt(.create(.service)) }
                        .keyboardShortcut("n", modifiers: .command)
                    Button("新建一次性命令") { model.attempt(.create(.oneshot)) }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                    Divider()
                    Button("从 supervisor 粘贴导入…") { onImport() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("添加程序")
                .help("新建程序或导入")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索程序…", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .help("搜索名称、命令或分组")
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            Picker("分组方式", selection: $model.sortMode) {
                ForEach(ConfigSortMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .controlSize(.small)
        }
        .padding(14)
    }

    // MARK: - Selection

    private var selectionBinding: Binding<Int64?> {
        Binding(
            get: { model.currentId },
            set: { model.attempt(.select($0)) }
        )
    }

    // MARK: - Grouping

    /// Reordering writes `priority`, so it is only offered when the visible order actually
    /// is the priority order — not while filtered or sorted some other way.
    private var canReorder: Bool {
        model.sortMode.allowsReorder && model.searchText.isEmpty
    }

    private var filtered: [ProgramSnapshot] {
        let all = appState.snapshot.programs
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.program.name.localizedCaseInsensitiveContains(query)
                || $0.program.command.localizedCaseInsensitiveContains(query)
                || ($0.program.groupName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var groups: [SidebarGroup] {
        let items = filtered
        switch model.sortMode {
        case .kind:
            return [
                SidebarGroup(id: "service", title: String(localized: "服务"), items: items.filter { $0.program.kind == .service }),
                SidebarGroup(id: "oneshot", title: String(localized: "一次性命令"), items: items.filter { $0.program.kind == .oneshot })
            ].filter { !$0.items.isEmpty }
        case .group:
            return bucket(items) { $0.program.groupName ?? String(localized: "默认") }
        case .state:
            return bucket(items) { snap in
                if snap.serviceState == .fatal { return String(localized: "启动失败") }
                if snap.isActive { return String(localized: "活动中") }
                return snap.program.kind == .service ? String(localized: "已停止") : String(localized: "空闲")
            }
        case .name:
            return [SidebarGroup(
                id: "all",
                title: String(localized: "全部"),
                items: items.sorted { $0.program.name.localizedCompare($1.program.name) == .orderedAscending }
            )].filter { !$0.items.isEmpty }
        }
    }

    private func bucket(_ items: [ProgramSnapshot], key: (ProgramSnapshot) -> String) -> [SidebarGroup] {
        var order: [String] = []
        var buckets: [String: [ProgramSnapshot]] = [:]
        for item in items {
            let name = key(item)
            if buckets[name] == nil { order.append(name) }
            buckets[name, default: []].append(item)
        }
        return order.map { SidebarGroup(id: $0, title: $0, items: buckets[$0] ?? []) }
    }

    private func move(groupId: String, from source: IndexSet, to destination: Int) {
        var ordered: [Int64] = []
        for group in groups {
            var items = group.items
            if group.id == groupId {
                items.move(fromOffsets: source, toOffset: destination)
            }
            ordered.append(contentsOf: items.map(\.id))
        }
        model.reorder(orderedIds: ordered)
    }
}

/// The unsaved-new-program placeholder, so the sidebar still shows where the user is.
private struct DraftRow: View {
    let program: Program

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(program.name.isEmpty ? String(localized: "未命名") : program.name).lineLimit(1)
                Text("未保存").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct ProgramRow: View {
    let snap: ProgramSnapshot
    let isDirty: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusGlyph(style: StatusStyle.presentation(for: snap), size: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(snap.program.name)
                    .lineLimit(1)
                    .foregroundStyle(snap.program.enabled ? .primary : .secondary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help(snap.program.command)
    }

    private var subtitle: String {
        var parts = [StatusStyle.presentation(for: snap).label]
        if !snap.program.enabled { parts.append(String(localized: "已停用")) }
        if isDirty { parts.insert(String(localized: "未保存"), at: 0) }
        return parts.joined(separator: " · ")
    }

}
