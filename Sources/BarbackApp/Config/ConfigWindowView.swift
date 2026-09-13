import SwiftUI
import BarbackCore

/// The sole configuration entry point (CFG-2). Toolbar for the primary actions, searchable
/// program list on the left, tabbed form on the right (design.md §6.5).
struct ConfigWindowView: View {
    @ObservedObject var model: ConfigWindowModel
    @ObservedObject var appState: AppState
    let onShowLog: (Int64) -> Void
    let onShowHistory: (Int64) -> Void
    let onShowImport: () -> Void

    var body: some View {
        NavigationSplitView {
            ConfigSidebarView(
                model: model,
                appState: appState,
                onImport: onShowImport,
                onShowLog: onShowLog,
                onShowHistory: onShowHistory
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
            .searchable(text: $model.searchText, placement: .sidebar, prompt: "搜索名称或命令")
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .confirmationDialog(
            "有未保存的更改",
            isPresented: unsavedPrompt,
            titleVisibility: .visible
        ) {
            Button("保存") { model.resolvePending(.save) }
            Button("放弃更改", role: .destructive) { model.resolvePending(.discard) }
            Button("取消", role: .cancel) { model.resolvePending(.cancel) }
        } message: {
            Text("「\(model.draft?.name ?? "")」有未保存的更改。切换后未保存的内容会丢失。")
        }
        .alert("删除「\(model.deleteTarget?.program.name ?? "")」？", isPresented: deletePrompt) {
            Button("删除", role: .destructive) { model.confirmDelete() }
            Button("取消", role: .cancel) { model.deleteTarget = nil }
        } message: {
            Text(deleteMessage)
        }
        .alert("保存失败", isPresented: saveFailurePrompt) {
            Button("好", role: .cancel) { model.saveFailure = nil }
        } message: {
            Text(model.saveFailure ?? "")
        }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if model.draft != nil {
            ProgramFormView(
                program: model.draftBinding,
                snapshot: model.selectedSnapshot,
                errors: model.visibleErrors,
                isDirty: model.isDirty,
                isNew: model.isCreatingNew,
                existingGroups: existingGroups,
                onSave: { model.save(restart: false) },
                onSaveAndRestart: { model.save(restart: true) },
                onRevert: { model.revert() },
                onRestartNow: { if let id = model.currentId, id > 0 { appState.supervisor.restart(id: id) } },
                onShowLog: { if let id = model.currentId, id > 0 { onShowLog(id) } },
                onShowHistory: { if let id = model.currentId, id > 0 { onShowHistory(id) } }
            )
        } else if appState.snapshot.programs.isEmpty {
            ConfigEmptyStateView(
                onCreate: { model.attempt(.create($0)) },
                onImport: onShowImport
            )
        } else {
            placeholder
        }
    }

    private var existingGroups: [String] {
        Array(Set(appState.snapshot.programs.compactMap(\.program.groupName))).sorted()
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("从左侧选择一个程序")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Button("新建服务") { model.attempt(.create(.service)) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("新建一次性命令") { model.attempt(.create(.oneshot)) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("从 supervisor 粘贴导入…") { onShowImport() }
            } label: {
                Label("新建", systemImage: "plus")
            }
            .labelStyle(.titleAndIcon)
            .help("新建服务或一次性命令")
        }

        ToolbarItemGroup(placement: .navigation) {
            Button {
                if let id = model.currentId, id > 0 { model.attempt(.duplicate(id)) }
            } label: {
                Label("复制", systemImage: "plus.square.on.square")
            }
            .disabled(model.selectedSnapshot == nil)
            .keyboardShortcut("d", modifiers: .command)
            .help("复制所选程序")

            Button {
                if let id = model.currentId, id > 0 { model.requestDelete(id: id) }
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(model.selectedSnapshot == nil)
            .keyboardShortcut(.delete, modifiers: .command)
            .help("删除所选程序")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("分组方式", selection: $model.sortMode) {
                    ForEach(ConfigSortMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("分组方式", systemImage: "arrow.up.arrow.down")
            }
            .help("更改列表分组方式")
        }
    }

    // MARK: - Alert plumbing

    private var unsavedPrompt: Binding<Bool> {
        Binding(
            get: { model.pendingNavigation != nil },
            set: { if !$0 { model.resolvePending(.cancel) } }
        )
    }

    private var deletePrompt: Binding<Bool> {
        Binding(
            get: { model.deleteTarget != nil },
            set: { if !$0 { model.deleteTarget = nil } }
        )
    }

    private var saveFailurePrompt: Binding<Bool> {
        Binding(
            get: { model.saveFailure != nil },
            set: { if !$0 { model.saveFailure = nil } }
        )
    }

    private var deleteMessage: String {
        guard let target = model.deleteTarget else { return "" }
        var parts = ["配置与执行历史会一并删除，此操作不可撤销。"]
        if target.isActive { parts.insert("该程序正在运行，删除前会先停止它。", at: 0) }
        return parts.joined(separator: "\n")
    }
}

/// First-run state: the window used to show nothing but a grey line of text.
struct ConfigEmptyStateView: View {
    let onCreate: (ProgramKind) -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("还没有任何程序")
                .font(.title3).bold()
            Text("添加一个常驻服务，或一条按需执行的命令。")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("新建服务") { onCreate(.service) }
                    .buttonStyle(.borderedProminent)
                Button("新建一次性命令") { onCreate(.oneshot) }
                Button("从 supervisor 粘贴导入…") { onImport() }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
