import SwiftUI
import BarbackCore

/// The sole configuration entry point (CFG-2): a searchable list on the left, a
/// section-based form on the right (design.md §6.5).
struct ConfigWindowView: View {
    @ObservedObject var appState: AppState
    @State private var selection: Int64?
    @State private var searchText = ""
    @State private var draft: Program?
    @State private var isDirty = false
    @State private var validationErrors: [ProgramValidationError] = []

    init(appState: AppState, initialSelection: Int64?) {
        self.appState = appState
        _selection = State(initialValue: initialSelection)
    }

    private var filteredPrograms: [ProgramSnapshot] {
        let all = appState.snapshot.programs
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.program.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("搜索…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(selection: $selection) {
                    Section("服务") {
                        ForEach(filteredPrograms.filter { $0.program.kind == .service }) { snap in
                            ProgramRow(snap: snap).tag(snap.id)
                        }
                    }
                    Section("一次性命令") {
                        ForEach(filteredPrograms.filter { $0.program.kind == .oneshot }) { snap in
                            ProgramRow(snap: snap).tag(snap.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                HStack {
                    Menu {
                        Button("新建服务") { createNew(kind: .service) }
                        Button("新建一次性命令") { createNew(kind: .oneshot) }
                    } label: {
                        Image(systemName: "plus")
                    }.menuStyle(.borderlessButton).frame(width: 24)
                    Button(action: deleteSelected) { Image(systemName: "minus") }.disabled(selection == nil)
                    Button(action: duplicateSelected) { Image(systemName: "plus.square.on.square") }.disabled(selection == nil)
                    Spacer()
                    Button("粘贴导入…") { NotificationCenter.default.post(name: .barbackShowImport, object: nil) }
                }
                .padding(8)
            }
        } detail: {
            if let draft {
                ProgramFormView(
                    program: Binding(get: { draft }, set: { self.draft = $0; isDirty = true }),
                    errors: validationErrors,
                    existingNames: Set(appState.snapshot.programs.map(\.program.name)).subtracting([draft.name]),
                    isRunning: appState.program(id: draft.id)?.isActive ?? false,
                    onSave: { save(andRestart: false) },
                    onSaveAndRestart: { save(andRestart: true) },
                    onRevert: { loadDraft(id: draft.id) }
                )
            } else {
                Text("选择或新建一个程序").foregroundStyle(.secondary)
            }
        }
        .onChange(of: selection) { newValue in
            if let newValue { loadDraft(id: newValue) } else { draft = nil }
        }
        .onAppear {
            if let selection { loadDraft(id: selection) }
        }
    }

    private func loadDraft(id: Int64) {
        appState.supervisor.snapshotProgram(id: id) { program in
            DispatchQueue.main.async {
                self.draft = program
                self.isDirty = false
                self.validationErrors = []
            }
        }
    }

    private func createNew(kind: ProgramKind) {
        let newProgram = Program(name: "新\(kind == .service ? "服务" : "命令")", kind: kind, command: "")
        draft = newProgram
        selection = nil
        isDirty = true
    }

    private func save(andRestart: Bool) {
        guard let draft else { return }
        appState.supervisor.validateAndSave(draft) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let saved):
                    self.draft = saved
                    self.selection = saved.id
                    self.isDirty = false
                    self.validationErrors = []
                    if andRestart, appState.program(id: saved.id)?.isActive == true {
                        appState.supervisor.restart(id: saved.id)
                    }
                case .failure(.validation(let errors)):
                    self.validationErrors = errors
                case .failure(.other):
                    self.validationErrors = []
                }
            }
        }
    }

    private func deleteSelected() {
        guard let selection else { return }
        appState.supervisor.deleteProgram(id: selection) {
            DispatchQueue.main.async {
                self.selection = nil
                self.draft = nil
            }
        }
    }

    private func duplicateSelected() {
        guard let draft else { return }
        var copy = draft
        copy.id = 0
        copy.name = draft.name + "-copy"
        self.draft = copy
        self.selection = nil
        isDirty = true
    }
}

extension Notification.Name {
    static let barbackShowImport = Notification.Name("barback.showImport")
}

private struct ProgramRow: View {
    let snap: ProgramSnapshot
    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(snap.program.name)
            Spacer()
        }
    }

    private var color: Color {
        switch snap.serviceState {
        case .running: return .green
        case .starting, .backoff: return .orange
        case .fatal: return .red
        default: return .gray
        }
    }
}
