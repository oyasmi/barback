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
            bottomBar
        }
    }

    private func row(for snap: ProgramSnapshot) -> some View {
        ProgramRow(snap: snap)
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
            Text("还没有程序").foregroundStyle(.secondary)
        } else {
            Text("没有匹配「\(model.searchText)」的程序").foregroundStyle(.secondary)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Menu {
                Button("新建服务") { model.attempt(.create(.service)) }
                Button("新建一次性命令") { model.attempt(.create(.oneshot)) }
                Divider()
                Button("从 supervisor 粘贴导入…") { onImport() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .help("新建程序")

            Button {
                if let id = model.currentId, id > 0 { model.requestDelete(id: id) }
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(model.selectedSnapshot == nil)
            .help("删除所选程序")

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
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
                SidebarGroup(id: "service", title: "服务", items: items.filter { $0.program.kind == .service }),
                SidebarGroup(id: "oneshot", title: "一次性命令", items: items.filter { $0.program.kind == .oneshot })
            ].filter { !$0.items.isEmpty }
        case .group:
            return bucket(items) { $0.program.groupName ?? "默认" }
        case .state:
            return bucket(items) { snap in
                if snap.serviceState == .fatal { return "启动失败" }
                if snap.isActive { return "活动中" }
                return snap.program.kind == .service ? "已停止" : "空闲"
            }
        case .name:
            return [SidebarGroup(
                id: "all",
                title: "全部",
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
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(program.name.isEmpty ? "未命名" : program.name).lineLimit(1)
                Text("未保存").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct ProgramRow: View {
    let snap: ProgramSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
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
        guard snap.program.enabled else { return "已停用" }
        if let pid = snap.pid { return "\(snap.statusText) · PID \(pid)" }
        return snap.statusText
    }

    private var dotColor: Color {
        guard snap.program.enabled else { return .secondary.opacity(0.4) }
        if let state = snap.serviceState {
            switch state {
            case .running: return .green
            case .starting, .backoff, .stopping: return .orange
            case .fatal: return .red
            case .stopped, .exited: return .secondary.opacity(0.5)
            }
        }
        switch snap.oneshotState {
        case .running: return .accentColor
        case .failed, .timeout: return .red
        default: return .secondary.opacity(0.5)
        }
    }
}
