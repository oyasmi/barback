import Foundation
import AppKit
import Testing
@testable import BarbackApp
@testable import BarbackCore

@MainActor
struct PanelInteractionTests {
    private func snapshot(_ program: Program, state: ServiceState = .running,
                          outcome: RunOutcome? = nil, executing: Bool = false) -> ProgramSnapshot {
        ProgramSnapshot(program: program, serviceState: program.kind == .service ? state : nil,
            oneshotState: program.kind == .oneshot ? (executing ? .running : .idle) : nil,
            pid: nil, startedAt: nil, retryCount: 0, backoffRemaining: nil,
            lastRun: outcome.map { RunRecord(programId: program.id, trigger: .manual, endedAt: Date(), outcome: $0) },
            runCount: 0, needsRestart: false)
    }

    private func makeState() throws -> (AppState, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store(dbPath: dir.appendingPathComponent("test.db").path, backupsDir: dir.appendingPathComponent("backups").path)
        return (AppState(supervisor: Supervisor(store: store, logsDir: dir.appendingPathComponent("logs").path), store: store), dir)
    }

    @Test func hiddenSelectionsNeverReceiveKeyboardActions() throws {
        let (state, dir) = try makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = snapshot(Program(id: 1, name: "alpha", kind: .service, command: "/bin/true"))
        let b = snapshot(Program(id: 2, name: "beta", kind: .service, command: "/bin/true"), state: .stopped)
        state.snapshot = SupervisorSnapshot(programs: [a, b], recoveredCount: 0)
        let model = StatusPanelModel(appState: state, windowController: nil)
        model.selectedId = a.id
        model.expandedId = a.id
        model.searchText = "beta"
        #expect(model.selectedId == nil)
        #expect(model.expandedId == nil)
        // Defensive check even if a stale ID is supplied between filter reconciliation and a key.
        model.selectedId = a.id
        #expect(model.selectedProgram == nil)
        model.searchText = ""
        model.filter = .stopped
        #expect(model.selectedId == nil)
        #expect(model.navigableIds == [b.id])
    }

    @Test func snapshotChangesReconcileSelectionBeforeKeyboardUse() throws {
        let (state, dir) = try makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let program = Program(id: 1, name: "service", kind: .service, command: "/bin/true")
        state.snapshot = SupervisorSnapshot(programs: [snapshot(program)], recoveredCount: 0)
        let model = StatusPanelModel(appState: state, windowController: nil)
        model.filter = .running
        model.selectedId = program.id
        model.expandedId = program.id
        state.snapshot = SupervisorSnapshot(programs: [], recoveredCount: 0)
        #expect(model.selectedProgram == nil)
        #expect(model.selectedId == nil)
        #expect(model.expandedId == nil)
    }

    @Test func modifiedArrowsRemainAvailableForTextEditing() throws {
        let (state, dir) = try makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.snapshot = SupervisorSnapshot(programs: [snapshot(Program(id: 1, name: "service", kind: .service, command: "/bin/true"))], recoveredCount: 0)
        let model = StatusPanelModel(appState: state, windowController: nil)
        let key = String(try #require(UnicodeScalar(Int(NSUpArrowFunctionKey))))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: 126))
        #expect(!model.handleKeyDown(event))
        #expect(model.selectedId == nil)
    }

    @Test func commandFailuresShareTheIconAndFilterPredicate() {
        let program = Program(id: 1, name: "command", kind: .oneshot, command: "/bin/true")
        let outcomes: [(RunOutcome, String)] = [
            (.succeeded, String(localized: "上次成功")),
            (.failed, String(localized: "上次失败")),
            (.timeout, String(localized: "上次超时")),
            (.cancelled, String(localized: "上次已中止")),
            (.unknown, String(localized: "上次结果未知"))
        ]
        for (outcome, label) in outcomes {
            let snap = snapshot(program, outcome: outcome)
            #expect(PanelFilter.oneshotProblem.matches(snap) == snap.hasOneshotProblem)
            #expect(snap.hasOneshotProblem == (outcome == .failed || outcome == .timeout))
            let style = StatusStyle.presentation(for: snap)
            #expect(!style.isBusy)
            #expect(style.symbol != "circle.fill")
            #expect(style.label == label)
        }
        #expect(!snapshot(program, outcome: .failed, executing: true).hasOneshotProblem)
    }

    @Test func reopeningHistoryChangesScopeAndResetsResultFilter() throws {
        let (state, dir) = try makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = HistoryWindowModel(appState: state, initialProgramId: 1)
        model.outcomeFilter = .failed
        model.selectProgram(2)
        #expect(model.selectedProgramId == 2)
        #expect(model.outcomeFilter == nil)
        model.selectProgram(nil)
        #expect(model.selectedProgramId == nil)
    }

    @Test func historyIgnoresResponsesFromPreviousScopes() async throws {
        let (state, dir) = try makeState()
        defer { try? FileManager.default.removeItem(at: dir) }
        var a = Program(name: "history-a", kind: .oneshot, command: "/bin/true")
        var b = Program(name: "history-b", kind: .oneshot, command: "/bin/true")
        a.id = try state.store.insertProgram(a)
        b.id = try state.store.insertProgram(b)
        _ = try state.store.insertRun(RunRecord(programId: a.id, trigger: .manual, endedAt: Date(), outcome: .failed))
        _ = try state.store.insertRun(RunRecord(programId: b.id, trigger: .manual, endedAt: Date(), outcome: .succeeded))
        state.snapshot = SupervisorSnapshot(programs: [snapshot(a), snapshot(b)], recoveredCount: 0)
        let model = HistoryWindowModel(appState: state, initialProgramId: a.id)
        model.start()
        defer { model.stop() }
        model.outcomeFilter = .failed
        model.selectProgram(b.id)
        model.outcomeFilter = .succeeded
        for _ in 0..<100 {
            if !model.isLoading { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!model.isLoading)
        #expect(model.totalCount == 1)
        #expect(model.runs.count == 1)
        #expect(model.runs.first?.programId == b.id)
        #expect(model.runs.first?.outcome == .succeeded)
    }
}
