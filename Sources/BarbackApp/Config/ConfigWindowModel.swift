import Foundation
import SwiftUI
import BarbackCore

/// How the sidebar groups programs. `.kind` keeps the stored `priority` order, so it is the
/// only mode where drag-to-reorder has a meaning to persist.
enum ConfigSortMode: String, CaseIterable, Identifiable {
    case kind
    case group
    case state
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kind: return "按类型"
        case .group: return "按分组"
        case .state: return "按状态"
        case .name: return "按名称"
        }
    }

    var allowsReorder: Bool { self == .kind }
}

/// A navigation the user asked for that may first need an unsaved-changes decision.
enum ConfigNavigation: Equatable {
    case select(Int64?)
    case create(ProgramKind)
    case duplicate(Int64)
}

enum UnsavedDecision {
    case save
    case discard
    case cancel
}

/// Owns the config window's editing state. Lives outside the SwiftUI view so that
/// `WindowController` can interrogate it from `windowShouldClose` (design.md §6.5:
/// "未保存时切换/关窗给确认") — a `@State` draft inside a view struct cannot be.
@MainActor
final class ConfigWindowModel: ObservableObject {
    /// Sidebar tag for the not-yet-saved draft row. Real ids are always positive.
    static let newDraftId: Int64 = -1

    let appState: AppState

    @Published var searchText = ""
    @Published var sortMode: ConfigSortMode = .kind
    @Published private(set) var currentId: Int64?
    @Published private(set) var isDirty = false
    @Published private(set) var errors: [ProgramValidationError] = []
    @Published private(set) var hasAttemptedSave = false
    @Published var saveFailure: String?
    @Published var pendingNavigation: ConfigNavigation?
    @Published var deleteTarget: ProgramSnapshot?

    @Published var draft: Program? {
        didSet { draftChanged() }
    }

    private var baseline: Program?
    /// The last non-nil draft, kept only to feed `draftBinding` — see the comment there.
    private var lastDraft: Program?
    private var validationTask: Task<Void, Never>?

    /// Set by `WindowController` to drive the title-bar edited dot.
    var onDirtyChange: ((Bool) -> Void)?

    init(appState: AppState, initialSelection: Int64?) {
        self.appState = appState
        if let initialSelection {
            select(id: initialSelection)
        }
    }

    // MARK: - Derived state

    var isCreatingNew: Bool { currentId == Self.newDraftId }

    /// A non-trapping `Binding` to the draft, for the detail form.
    ///
    /// `Binding($model.draft)` reads equivalently but force-unwraps on every get. Clearing
    /// the draft — deleting the selected program, reverting a new one — does not retire the
    /// form's bindings synchronously: SwiftUI still refreshes them once in the same
    /// transaction that re-evaluates the parent, and that read crashes the app
    /// (EXC_BREAKPOINT in `BindingOperations.ForceUnwrapping.get`). Falling back to the last
    /// draft keeps that final read harmless, and the write is dropped because the form is on
    /// its way out.
    var draftBinding: Binding<Program> {
        Binding(
            get: { [weak self] in
                self?.draft ?? self?.lastDraft ?? Program(name: "", kind: .service, command: "")
            },
            set: { [weak self] newValue in
                guard let self, self.draft != nil else { return }
                self.draft = newValue
            }
        )
    }

    /// The live snapshot behind the current selection; `nil` while editing an unsaved draft.
    var selectedSnapshot: ProgramSnapshot? {
        guard let currentId, currentId > 0 else { return nil }
        return appState.program(id: currentId)
    }

    /// Emptiness complaints are noise until the user has actually tried to save a new
    /// program, so they stay hidden during the first pass through the form.
    var visibleErrors: [ProgramValidationError] {
        guard !hasAttemptedSave else { return errors }
        return errors.filter { $0 != .emptyCommand }
    }

    // MARK: - Navigation, gated on unsaved changes

    func attempt(_ navigation: ConfigNavigation) {
        if case .select(let id) = navigation, id == currentId { return }
        guard isDirty else {
            perform(navigation)
            return
        }
        pendingNavigation = navigation
    }

    func resolvePending(_ decision: UnsavedDecision) {
        guard let navigation = pendingNavigation else { return }
        pendingNavigation = nil
        switch decision {
        case .cancel:
            break
        case .discard:
            perform(navigation)
        case .save:
            save(restart: false) { [weak self] succeeded in
                guard succeeded else { return }
                self?.perform(navigation)
            }
        }
    }

    private func perform(_ navigation: ConfigNavigation) {
        switch navigation {
        case .select(let id): select(id: id)
        case .create(let kind): createNew(kind: kind)
        case .duplicate(let id): duplicate(id: id)
        }
    }

    // MARK: - Draft lifecycle

    private func select(id: Int64?) {
        currentId = id
        errors = []
        saveFailure = nil
        hasAttemptedSave = false
        guard let id, id > 0 else {
            setDraft(nil, baseline: nil)
            return
        }
        appState.supervisor.snapshotProgram(id: id) { program in
            Task { @MainActor in
                // A slow snapshot must not clobber a selection the user has moved on from.
                guard self.currentId == id else { return }
                self.setDraft(program, baseline: program)
            }
        }
    }

    private func createNew(kind: ProgramKind) {
        currentId = Self.newDraftId
        errors = []
        saveFailure = nil
        hasAttemptedSave = false
        let base = kind == .service ? "new-service" : "new-command"
        var draft = Program(name: uniqueName(base: base), kind: kind, command: "")
        // A service's run history isn't user-facing (no "历史保留" field shows for it — see
        // `LogTab`/`ExecutionTab`), it's just the FIFO cap `trimHistoryIfNeeded` trims against.
        // A restarting service accumulates rows far faster than a manually-run one-shot, so it
        // gets more headroom before trimming kicks in (design.md §3.4, ex-F09).
        if kind == .service { draft.historyLimit = 200 }
        setDraft(draft, baseline: nil)
    }

    private func duplicate(id: Int64) {
        guard let source = appState.program(id: id)?.program else { return }
        var copy = source
        copy.id = 0
        copy.name = uniqueName(base: source.name + "-copy")
        currentId = Self.newDraftId
        errors = []
        saveFailure = nil
        hasAttemptedSave = false
        setDraft(copy, baseline: nil)
    }

    func revert() {
        hasAttemptedSave = false
        errors = []
        if let baseline {
            setDraft(baseline, baseline: baseline)
        } else if isCreatingNew {
            select(id: nil)
        }
    }

    /// Drops the draft without touching the store — used when the window closes on "不保存".
    func discardDraft() {
        setDraft(baseline, baseline: baseline)
    }

    func save(restart: Bool, completion: (@Sendable @MainActor (Bool) -> Void)? = nil) {
        guard let draft else {
            completion?(true)
            return
        }
        hasAttemptedSave = true
        let wasActive = appState.program(id: draft.id)?.isActive ?? false
        appState.supervisor.validateAndSave(draft) { result in
            Task { @MainActor in
                switch result {
                case .success(let saved):
                    self.currentId = saved.id
                    self.setDraft(saved, baseline: saved)
                    self.errors = []
                    self.saveFailure = nil
                    self.hasAttemptedSave = false
                    if restart, wasActive {
                        self.appState.supervisor.restart(id: saved.id)
                    }
                    completion?(true)
                case .failure(.validation(let errors)):
                    self.errors = errors
                    completion?(false)
                case .failure(.other(let message)):
                    self.saveFailure = message
                    completion?(false)
                }
            }
        }
    }

    func requestDelete(id: Int64) {
        deleteTarget = appState.program(id: id)
    }

    func confirmDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        let neighbor = neighborId(of: target.id)
        appState.supervisor.deleteProgram(id: target.id) {
            Task { @MainActor in
                self.setDraft(nil, baseline: nil)
                self.select(id: neighbor)
            }
        }
    }

    /// Persists a drag-reordered sidebar as new `priority` values.
    func reorder(orderedIds: [Int64]) {
        appState.supervisor.reorderPrograms(orderedIds: orderedIds) {}
    }

    // MARK: - Internals

    private func setDraft(_ value: Program?, baseline: Program?) {
        self.baseline = baseline
        if let value { lastDraft = value }
        self.draft = value
    }

    private func draftChanged() {
        let dirty: Bool
        if let draft {
            dirty = baseline.map { $0 != draft } ?? true
        } else {
            dirty = false
        }
        if dirty != isDirty {
            isDirty = dirty
            onDirtyChange?(dirty)
        }
        scheduleValidation()
    }

    /// Debounced so that validation — which stats the filesystem to resolve the executable
    /// and the working directory — does not run on every keystroke.
    private func scheduleValidation() {
        validationTask?.cancel()
        guard draft != nil else {
            errors = []
            return
        }
        validationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.validateNow()
        }
    }

    private func validateNow() {
        guard let draft else { return }
        var names = Set(appState.snapshot.programs.map(\.program.name))
        if draft.id != 0 {
            names.remove(appState.program(id: draft.id)?.program.name ?? "")
        }
        errors = ProgramValidator.validate(draft, existingNames: names)
    }

    private func uniqueName(base: String) -> String {
        let existing = Set(appState.snapshot.programs.map(\.program.name))
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    /// The row to select after deleting `id`: the next one down, else the previous one.
    private func neighborId(of id: Int64) -> Int64? {
        let ids = appState.snapshot.programs.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return nil }
        if index + 1 < ids.count { return ids[index + 1] }
        if index > 0 { return ids[index - 1] }
        return nil
    }
}
