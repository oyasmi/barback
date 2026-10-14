import SwiftUI
import BarbackCore

struct HistoryWindowView: View {
    @ObservedObject var model: HistoryWindowModel
    @ObservedObject var appState: AppState
    @State private var viewingRun: RunRecord?
    let onRerun: (RunRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("程序", selection: $model.selectedProgramId) {
                    Text("全部").tag(Int64?.none)
                    ForEach(appState.snapshot.programs) { p in
                        Text(p.program.name).tag(Int64?.some(p.id))
                    }
                }.frame(maxWidth: 240)
                Picker("结果", selection: $model.outcomeFilter) {
                    Text("全部").tag(RunOutcome?.none)
                    ForEach(RunOutcome.allCases, id: \.self) { outcome in
                        Text(outcome.displayText).tag(RunOutcome?.some(outcome))
                    }
                }.frame(maxWidth: 160)
                Spacer()
                Button("刷新") { model.reload() }
                Button("清理历史…", role: .destructive) { model.prepareClear() }
                    .disabled(model.isLoading || model.isPreparingClear || model.totalCount == 0)
            }
            .padding(10)
            .disabled(model.isClearing)
            Divider()
            Table(model.runs) {
                TableColumn("程序") { run in
                    Text(programName(run.programId)).help(programName(run.programId))
                }.width(min: 90, ideal: 130)
                TableColumn("时间") { run in Text(Self.timeFormatter.string(from: run.startedAt)) }
                    .width(min: 120, ideal: 140)
                TableColumn("触发") { run in Text(run.trigger.displayText) }
                TableColumn("结果") { run in
                    Label(run.outcome?.displayText ?? String(localized: "运行中"),
                          systemImage: run.outcome.map(StatusStyle.outcomeSymbol) ?? "circle.dotted")
                        .foregroundStyle(run.outcome.map(StatusStyle.outcomeColor) ?? .secondary)
                }
                TableColumn("耗时") { run in Text(run.duration.map(StatusStyle.runDuration) ?? "—") }
                TableColumn("退出码") { run in Text(run.exitCode.map(String.init) ?? "—") }
                TableColumn("操作") { run in
                    Menu("操作") {
                        Button("查看输出") { viewingRun = run }
                        if appState.program(id: run.programId)?.program.kind == .oneshot {
                            Divider()
                            Button("用当前配置再次运行…") { onRerun(run) }
                                .disabled(rerunUnavailableReason(run) != nil)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .help(rerunUnavailableReason(run) ?? String(localized: "查看本次输出，或用当前配置再次运行"))
                }.width(70)
            }
            .disabled(model.isClearing)
            .overlay {
                if model.isLoading && model.runs.isEmpty {
                    ProgressView().controlSize(.small)
                } else if !model.isLoading && model.runs.isEmpty {
                    ContentUnavailableView("暂无符合条件的执行记录", systemImage: "clock.arrow.circlepath",
                                           description: Text("调整上方的筛选条件，或运行一个程序。"))
                }
            }
            Divider()
            HStack {
                Text(model.feedback ?? String(localized: "已显示 \(model.runs.count) / \(model.totalCount) 条记录"))
                Spacer()
                if model.isLoading || model.isPreparingClear || model.isClearing {
                    ProgressView().controlSize(.small)
                }
                if model.runs.count < model.totalCount {
                    Button("加载更多") { model.loadMore() }
                        .disabled(model.isLoading || model.isClearing)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.selectedProgramId) { viewingRun = nil }
        .sheet(item: $viewingRun) { run in
            RunOutputSheet(run: run, programName: programName(run.programId))
        }
        .alert("清理这些执行记录？", isPresented: clearPrompt, presenting: model.clearPlan) { plan in
            Button("清理", role: .destructive) { model.clear(plan) }
            Button("取消", role: .cancel) { model.clearPlan = nil }
        } message: { plan in
            Text("范围：\(plan.scope)\n将删除 \(plan.records.count) 条已结束记录及其输出文件，包含尚未加载的记录。确认期间新增或结束的记录会保留，此操作不可撤销。")
        }
        .alert("历史操作失败", isPresented: failurePrompt) {
            Button("好", role: .cancel) { model.failure = nil }
        } message: { Text(model.failure ?? "") }
    }

    private var clearPrompt: Binding<Bool> {
        Binding(get: { model.clearPlan != nil }, set: { if !$0 { model.clearPlan = nil } })
    }

    private var failurePrompt: Binding<Bool> {
        Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })
    }

    private func programName(_ id: Int64) -> String {
        appState.program(id: id)?.program.name ?? String(localized: "已删除的程序")
    }

    private func rerunUnavailableReason(_ run: RunRecord) -> String? {
        guard let snap = appState.program(id: run.programId) else { return String(localized: "程序已删除") }
        if snap.isActive || run.endedAt == nil { return String(localized: "命令正在执行，结束后才能再次运行") }
        return nil
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

private struct RunOutputSheet: View {
    let run: RunRecord
    let programName: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.Key.logFontSize) private var fontSize = 11.0
    @State private var automaticallyScrolls = true
    @StateObject private var model: LogTailModel

    init(run: RunRecord, programName: String) {
        self.run = run
        self.programName = programName
        _model = StateObject(wrappedValue: LogTailModel(path: run.logPath ?? ""))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(programName).font(.headline)
                    Text("\(StatusStyle.timestamp(run.startedAt)) · #\(run.id)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            if run.logPath != nil {
                LogTextView(model: model, revision: model.revision, fontSize: fontSize,
                            automaticallyScrolls: $automaticallyScrolls)
                Text(model.loadedRangeDescription)
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            } else {
                ContentUnavailableView("无输出文件", systemImage: "doc")
            }
        }
        .frame(width: 680, height: 440)
        .onAppear { if run.logPath != nil { model.start() } }
        .onDisappear { model.stop() }
    }
}
