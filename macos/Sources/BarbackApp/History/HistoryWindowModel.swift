import BarbackCore
import Combine
import Foundation

@MainActor
final class HistoryWindowModel: ObservableObject {
    let appState: AppState
    @Published var selectedProgramId: Int64? { didSet { scopeChanged() } }
    @Published var outcomeFilter: RunOutcome? { didSet { scopeChanged() } }
    @Published private(set) var runs: [RunRecord] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isPreparingClear = false
    @Published private(set) var isClearing = false
    @Published var clearPlan: ClearPlan?
    @Published var failure: String?
    @Published private(set) var feedback: String?

    struct ClearPlan: Identifiable {
        let id = UUID()
        let records: [RunRecord]
        let scope: String
    }

    private var pageLimit = 500
    private var requestId = UUID()
    private var clearRequestId = UUID()
    private var isVisible = false
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState, initialProgramId: Int64?) {
        self.appState = appState
        self.selectedProgramId = initialProgramId
        appState.$snapshot.sink { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible else { return }
                if let id = self.selectedProgramId, !self.appState.snapshot.programs.contains(where: { $0.id == id }) {
                    self.selectProgram(nil)
                } else {
                    self.reload()
                }
            }
        }.store(in: &cancellables)
    }

    func selectProgram(_ id: Int64?) {
        outcomeFilter = nil
        selectedProgramId = id
    }

    func start() { isVisible = true; reload() }
    func stop() {
        isVisible = false
        requestId = UUID()
        clearRequestId = UUID()
    }

    private func scopeChanged() {
        pageLimit = 500
        runs = []
        totalCount = 0
        feedback = nil
        clearPlan = nil
        clearRequestId = UUID()
        isPreparingClear = false
        if isVisible { reload() }
    }

    func loadMore() { pageLimit += 500; reload() }

    func reload() {
        let token = UUID()
        requestId = token
        isLoading = true
        appState.supervisor.fetchHistory(programId: selectedProgramId, outcome: outcomeFilter, limit: pageLimit) { [weak self] result in
            Task { @MainActor in
                guard let self, self.requestId == token, self.isVisible else { return }
                self.isLoading = false
                switch result {
                case .success(let page):
                    self.runs = page.runs
                    self.totalCount = page.totalCount
                case .failure(let error): self.failure = error.localizedDescription
                }
            }
        }
    }

    func prepareClear() {
        guard !isPreparingClear, !isClearing else { return }
        let token = UUID()
        clearRequestId = token
        isPreparingClear = true
        let name = selectedProgramId.flatMap { appState.program(id: $0)?.program.name } ?? String(localized: "全部程序")
        let scope = name + " · " + (outcomeFilter?.displayText ?? String(localized: "全部结果"))
        appState.supervisor.prepareHistoryClear(programId: selectedProgramId, outcome: outcomeFilter) { [weak self] result in
            Task { @MainActor in
                guard let self, self.clearRequestId == token, self.isVisible else { return }
                self.isPreparingClear = false
                switch result {
                case .success(let records):
                    if records.isEmpty { self.feedback = String(localized: "没有可清理的已结束记录") }
                    else { self.clearPlan = ClearPlan(records: records, scope: scope) }
                case .failure(let error): self.failure = error.localizedDescription
                }
            }
        }
    }

    func clear(_ plan: ClearPlan) {
        clearPlan = nil
        isClearing = true
        appState.supervisor.clearHistory(records: plan.records) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isClearing = false
                switch result {
                case .success(let count): self.feedback = String(localized: "已清理 \(count) 条记录")
                case .failure(let error): self.failure = error.localizedDescription
                }
                if self.isVisible { self.reload() }
            }
        }
    }
}
