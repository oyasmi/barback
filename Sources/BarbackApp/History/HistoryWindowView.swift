import SwiftUI
import BarbackCore

/// Run-history table: time / command / result / duration / exit code, filterable
/// (design.md §6.6, ONE-5).
struct HistoryWindowView: View {
    @ObservedObject var appState: AppState
    @State var selectedProgramId: Int64?
    @State private var runs: [RunRecord] = []
    @State private var outcomeFilter: RunOutcome?
    @State private var viewingRun: RunRecord?
    @State private var confirmingClear = false
    let onRerun: (Int64) -> Void

    init(appState: AppState, initialProgramId: Int64?, onRerun: @escaping (Int64) -> Void) {
        self.appState = appState
        _selectedProgramId = State(initialValue: initialProgramId)
        self.onRerun = onRerun
    }

    private var programOptions: [ProgramSnapshot] {
        appState.snapshot.programs
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("命令", selection: $selectedProgramId) {
                    Text("全部").tag(Int64?.none)
                    ForEach(programOptions) { p in
                        Text(p.program.name).tag(Int64?.some(p.id))
                    }
                }.frame(maxWidth: 240)
                Picker("结果", selection: $outcomeFilter) {
                    Text("全部").tag(RunOutcome?.none)
                    ForEach(RunOutcome.allCases, id: \.self) { outcome in
                        Text(outcome.displayText).tag(RunOutcome?.some(outcome))
                    }
                }.frame(maxWidth: 160)
                Spacer()
                Button("刷新") { reload() }
                Button("清理历史", role: .destructive) { confirmingClear = true }
            }
            .padding(8)
            Divider()
            Table(filteredRuns) {
                TableColumn("时间") { run in Text(Self.timeFormatter.string(from: run.startedAt)) }
                TableColumn("触发") { run in Text(run.trigger.displayText) }
                TableColumn("结果") { run in
                    Text(run.outcome?.displayText ?? "运行中")
                        .foregroundStyle(run.outcome.map { StatusStyle.outcomeColor($0) } ?? .secondary)
                }
                TableColumn("耗时") { run in Text(run.duration.map { String(format: "%.1fs", $0) } ?? "—") }
                TableColumn("退出码") { run in Text(run.exitCode.map(String.init) ?? "—") }
                TableColumn("") { run in
                    Button("查看输出") { viewingRun = run }
                    // "重跑" on a service's own row used to spawn it through the one-shot
                    // path unconditionally — an untracked `OneshotRuntime` for a program the
                    // service state machine already owns, invisible to stop/停止全部/quit, and
                    // bypassing confirmBeforeRun on the way in (design.md §3.4, ex-F03). Only
                    // a one-shot's own history can be re-run, and only through the path that
                    // already handles that confirmation.
                    if programKind(run.programId) == .oneshot {
                        Button("重跑") { onRerun(run.programId) }
                    }
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: selectedProgramId) { _ in reload() }
        .sheet(item: $viewingRun) { run in
            RunOutputSheet(run: run)
        }
        .alert("清理这些执行记录？", isPresented: $confirmingClear) {
            Button("清理", role: .destructive) { clearHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除当前筛选范围内已结束的执行记录及其输出文件，此操作不可撤销。")
        }
    }

    private var filteredRuns: [RunRecord] {
        guard let outcomeFilter else { return runs }
        return runs.filter { $0.outcome == outcomeFilter }
    }

    private func programKind(_ programId: Int64) -> ProgramKind? {
        appState.program(id: programId)?.program.kind
    }

    private func reload() {
        appState.supervisor.fetchRuns(programId: selectedProgramId, limit: 500) { fetched in
            DispatchQueue.main.async { self.runs = fetched }
        }
    }

    private func clearHistory() {
        appState.supervisor.clearHistory(programId: selectedProgramId, outcome: outcomeFilter) {
            DispatchQueue.main.async { reload() }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()
}

private struct RunOutputSheet: View {
    let run: RunRecord
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.Key.logFontSize) private var fontSize = 11.0
    // `String(contentsOfFile:)` had no size limit at all — a one-shot that printed a few
    // hundred MB made this sheet hang or get killed by the system the moment "查看输出" was
    // clicked, while the live log viewer next to it already bounds itself to 2 MB / 5000
    // lines for exactly this reason (design.md §4, ex-F19). Reusing that model here instead
    // of rolling a second, unbounded read path.
    @StateObject private var model: LogTailModel

    init(run: RunRecord) {
        self.run = run
        _model = StateObject(wrappedValue: LogTailModel(path: run.logPath ?? ""))
    }

    var body: some View {
        VStack {
            HStack {
                Text("输出").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
            }.padding()
            if run.logPath != nil {
                LogTextView(text: model.displayText(matching: ""), fontSize: fontSize)
            } else {
                Text("无输出文件").foregroundStyle(.secondary)
            }
        }
        .frame(width: 600, height: 400)
        .onAppear { if run.logPath != nil { model.start() } }
        .onDisappear { model.stop() }
    }
}
