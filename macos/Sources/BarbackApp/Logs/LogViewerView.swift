import SwiftUI
import AppKit
import BarbackCore

/// The program entry follows the latest run; a history sheet stays pinned to its run.
struct ProgramLogViewerView: View {
    @ObservedObject var appState: AppState
    let programId: Int64

    var body: some View {
        if let snap = appState.program(id: programId) {
            if snap.program.kind == .oneshot && snap.lastRun == nil {
                ContentUnavailableView("尚未执行", systemImage: "terminal",
                                       description: Text("执行命令后，这里会显示本次输出。"))
            } else {
                let path = ProgramLogPath.resolve(for: snap)
                LogViewerView(programName: snap.program.name, path: path,
                              run: snap.program.kind == .oneshot ? snap.lastRun : nil)
                    .id(path)
            }
        } else {
            ContentUnavailableView("程序已删除", systemImage: "trash")
        }
    }
}

struct LogViewerView: View {
    let programName: String
    let path: String
    var run: RunRecord?

    @StateObject private var model: LogTailModel
    @State private var filterText = ""
    @State private var isPaused = false
    @State private var automaticallyScrolls = true
    @State private var scrollRequest = 0
    @State private var findRequest = 0
    @State private var confirmingClear = false
    @AppStorage(Preferences.Key.logFontSize) private var fontSize = 11.0

    init(programName: String, path: String, run: RunRecord? = nil) {
        self.programName = programName
        self.path = path
        self.run = run
        _model = StateObject(wrappedValue: LogTailModel(path: path))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(programName).font(.headline).lineLimit(1).help(programName)
                if let run {
                    Text("\(StatusStyle.timestamp(run.startedAt)) · #\(run.id)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(run.outcome?.displayText ?? String(localized: "执行中"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 12).padding(.top, 10)
            HStack(spacing: 10) {
                Toggle("自动滚动", isOn: $automaticallyScrolls)
                Toggle("暂停更新", isOn: $isPaused)
                    .onChange(of: isPaused) { _, paused in
                        if paused { model.pauseFollowing() } else { model.resumeFollowing() }
                    }
                Button("回到最新") { automaticallyScrolls = true; scrollRequest += 1 }
                Spacer()
                Button("查找…") { findRequest += 1 }
                Menu("更多") {
                    Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                    Button("外部打开") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    Divider()
                    Button("清空日志…", role: .destructive) { confirmingClear = true }
                }
            }
            .controlSize(.small)
            .padding(10)
            HStack {
                TextField("过滤当前日志", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .help("仅过滤已加载内容；查找保留上下文并高亮匹配")
                if !filterText.isEmpty {
                    Button { filterText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("清除筛选")
                    Text("匹配 \(model.matchingLineCount(filterText)) 行")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isPaused { Text("更新已暂停").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            LogTextView(model: model, query: filterText, revision: model.revision, fontSize: fontSize,
                        automaticallyScrolls: $automaticallyScrolls, scrollRequest: scrollRequest, findRequest: findRequest)
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text(model.loadedRangeDescription).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(path).lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled)
                    Spacer()
                    Text(model.sizeDescription)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert("清空日志文件？", isPresented: $confirmingClear) {
            Button("清空", role: .destructive) { model.clearFile() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将截断磁盘上的「\(model.fileName)」，已写入的内容无法恢复。")
        }
        .alert("日志操作失败", isPresented: Binding(
            get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }
        )) {
            Button("好", role: .cancel) { model.failure = nil }
        } message: { Text(model.failure ?? "") }
    }
}

/// NSTextView supplies native find/highlight/next/previous without filtering away context.
struct LogTextView: NSViewRepresentable {
    let model: LogTailModel
    var query: String = ""
    let revision: Int
    var fontSize: Double = 11
    var automaticallyScrolls: Binding<Bool> = .constant(true)
    var scrollRequest = 0
    var findRequest = 0

    @MainActor
    final class Coordinator {
        var revision = -1
        var query = ""
        var fontSize = 0.0
        var wasFollowing = false
        var scrollRequest = 0
        var findRequest = 0
        var isApplyingUpdate = false
        var following: Binding<Bool> = .constant(true)
        var scrollObserver: NSObjectProtocol?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        scrollView.contentView.postsBoundsChangedNotifications = true
        let coordinator = context.coordinator
        coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak coordinator, weak scrollView] _ in
            MainActor.assumeIsolated {
                guard let coordinator, let scrollView, !coordinator.isApplyingUpdate else { return }
                let distance = (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.maxY
                if distance >= 40 && coordinator.following.wrappedValue {
                    DispatchQueue.main.async { [weak coordinator] in coordinator?.following.wrappedValue = false }
                }
            }
        }
        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.scrollObserver { NotificationCenter.default.removeObserver(observer) }
        coordinator.scrollObserver = nil
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let coordinator = context.coordinator
        coordinator.following = automaticallyScrolls
        coordinator.isApplyingUpdate = true
        defer { coordinator.isApplyingUpdate = false }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if coordinator.fontSize != fontSize {
            textView.font = font
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
            coordinator.fontSize = fontSize
        }
        if coordinator.revision != revision || coordinator.query != query {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
            storage.beginEditing()
            if query.isEmpty, coordinator.query.isEmpty,
               let from = model.changeStart(since: coordinator.revision), from <= storage.length {
                let tail = NSAttributedString(string: model.text(fromUTF16: from), attributes: attributes)
                storage.replaceCharacters(in: NSRange(location: from, length: storage.length - from), with: tail)
            } else {
                storage.setAttributedString(NSAttributedString(string: model.displayText(matching: query), attributes: attributes))
            }
            storage.endEditing()
            coordinator.revision = revision
            coordinator.query = query
            if automaticallyScrolls.wrappedValue { textView.scrollToEndOfDocument(nil) }
        }
        if scrollRequest != coordinator.scrollRequest || (automaticallyScrolls.wrappedValue && !coordinator.wasFollowing) {
            textView.scrollToEndOfDocument(nil)
        }
        coordinator.scrollRequest = scrollRequest
        coordinator.wasFollowing = automaticallyScrolls.wrappedValue
        if findRequest != coordinator.findRequest {
            nsView.window?.makeFirstResponder(textView)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(item)
            coordinator.findRequest = findRequest
        }
    }
}
