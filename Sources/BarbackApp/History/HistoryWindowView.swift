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

    init(appState: AppState, initialProgramId: Int64?) {
        self.appState = appState
        _selectedProgramId = State(initialValue: initialProgramId)
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
                    ForEach([RunOutcome.succeeded, .failed, .timeout, .cancelled, .unknown], id: \.self) { o in
                        Text(o.rawValue).tag(RunOutcome?.some(o))
                    }
                }.frame(maxWidth: 160)
                Spacer()
                Button("刷新") { reload() }
                Button("清理历史", role: .destructive) { clearHistory() }
            }
            .padding(8)
            Divider()
            Table(filteredRuns) {
                TableColumn("时间") { run in Text(format(run.startedAt)) }
                TableColumn("触发") { run in Text(run.trigger.rawValue) }
                TableColumn("结果") { run in Text(run.outcome?.rawValue ?? "运行中") }
                TableColumn("耗时") { run in Text(run.duration.map { String(format: "%.1fs", $0) } ?? "—") }
                TableColumn("退出码") { run in Text(run.exitCode.map(String.init) ?? "—") }
                TableColumn("") { run in
                    Button("查看输出") { viewingRun = run }
                    Button("重跑") { rerun(run) }
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: selectedProgramId) { _ in reload() }
        .sheet(item: $viewingRun) { run in
            RunOutputSheet(run: run)
        }
    }

    private var filteredRuns: [RunRecord] {
        guard let outcomeFilter else { return runs }
        return runs.filter { $0.outcome == outcomeFilter }
    }

    private func reload() {
        appState.supervisor.fetchRuns(programId: selectedProgramId, limit: 500) { fetched in
            DispatchQueue.main.async { self.runs = fetched }
        }
    }

    private func rerun(_ run: RunRecord) {
        appState.supervisor.runOneshot(id: run.programId)
    }

    private func clearHistory() {
        // Deletion of arbitrary history rows outside the FIFO trim is deferred; menu offers
        // the common case (trim runs on every execution per program's historyLimit already).
        reload()
    }

    private func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}

private struct RunOutputSheet: View {
    let run: RunRecord
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.Key.logFontSize) private var fontSize = 11.0

    var body: some View {
        VStack {
            HStack {
                Text("输出").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
            }.padding()
            if let path = run.logPath {
                LogTextView(text: (try? String(contentsOfFile: path, encoding: .utf8)) ?? "(无输出)", fontSize: fontSize)
            } else {
                Text("无输出文件").foregroundStyle(.secondary)
            }
        }
        .frame(width: 600, height: 400)
    }
}
