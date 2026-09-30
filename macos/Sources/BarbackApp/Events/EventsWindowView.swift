import SwiftUI
import BarbackCore

/// Event log table: time / level / object / type / detail, filterable and exportable
/// (design.md §6.6, APP-3).
struct EventsWindowView: View {
    @ObservedObject var appState: AppState
    @State private var events: [EventRecord] = []
    @State private var levelFilter: EventLevel?
    @State private var programFilter: Int64?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("对象", selection: $programFilter) {
                    Text("全部").tag(Int64?.none)
                    ForEach(appState.snapshot.programs) { p in
                        Text(p.program.name).tag(Int64?.some(p.id))
                    }
                }.frame(maxWidth: 220)
                Picker("级别", selection: $levelFilter) {
                    Text("全部").tag(EventLevel?.none)
                    Text("info").tag(EventLevel?.some(.info))
                    Text("warn").tag(EventLevel?.some(.warn))
                    Text("error").tag(EventLevel?.some(.error))
                }.frame(maxWidth: 160)
                Spacer()
                Button("刷新") { reload() }
                Button("导出…") { exportEvents() }
            }
            .padding(8)
            Divider()
            Table(events) {
                TableColumn("时间") { e in Text(format(e.ts)) }
                TableColumn("级别") { e in Text(e.level.rawValue).foregroundStyle(color(for: e.level)) }
                TableColumn("对象") { e in Text(programName(e.programId)) }
                TableColumn("类型") { e in Text(e.type.displayText) }
                TableColumn("详情") { e in
                    Text(EventPresentation.detail(for: e))
                        .lineLimit(1)
                        .help(e.detailJSON)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: levelFilter) { _ in reload() }
        .onChange(of: programFilter) { _ in reload() }
    }

    private func programName(_ id: Int64?) -> String {
        guard let id, let snap = appState.program(id: id) else { return "—" }
        return snap.program.name
    }

    private func color(for level: EventLevel) -> Color {
        switch level {
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func reload() {
        appState.supervisor.fetchEvents(limit: 1000, programId: programFilter, level: levelFilter) { fetched in
            DispatchQueue.main.async { self.events = fetched }
        }
    }

    private func exportEvents() {
        // Rendered before the panel opens, so the completion handler carries nothing but a
        // string — and so the exported rows say the same thing the table on screen does.
        // A leading BOM makes Excel read the file as UTF-8 instead of mojibake, and the time
        // column is an ISO timestamp rather than the raw epoch double the rows carry.
        let formatter = ISO8601DateFormatter()
        var csv = "\u{FEFF}time,level,program,type,detail\n"
        for event in events {
            let fields = [
                formatter.string(from: event.ts),
                event.level.rawValue,
                programName(event.programId),
                event.type.displayText,
                EventPresentation.detail(for: event)
            ]
            csv += fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") + "\n"
        }
        let document = csv
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "barback-events.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? document.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func format(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    // `DateFormatter` is one of the more expensive Foundation objects to construct — building
    // a fresh one per table cell added up fast on an event log with hundreds of rows
    // (design.md §6.6, ex-F20).
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()
}
