import SwiftUI
import AppKit

/// Tails a log file (design.md §4, LOG-4/5): loads only the tail window on open, follows
/// via a filesystem event source, and stops watching entirely when the window closes.
struct LogViewerView: View {
    let programName: String
    let path: String

    @StateObject private var model: LogTailModel
    @State private var searchText = ""
    @State private var isFollowing = true
    @State private var confirmingClear = false
    @AppStorage(Preferences.Key.logFontSize) private var fontSize = 11.0

    init(programName: String, path: String) {
        self.programName = programName
        self.path = path
        _model = StateObject(wrappedValue: LogTailModel(path: path))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("跟随", isOn: $isFollowing)
                    .onChange(of: isFollowing) { _, newValue in
                        if newValue { model.resumeFollowing() } else { model.pauseFollowing() }
                    }
                TextField("搜索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                Button("清空") { confirmingClear = true }
                Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                Button("外部打开") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
            .padding(8)
            Divider()
            LogTextView(model: model, query: searchText, revision: model.revision, fontSize: fontSize)
            Divider()
            HStack {
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(model.sizeDescription).font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        // Truncating the file is irreversible and also affects every other viewer of it.
        .alert("清空日志文件？", isPresented: $confirmingClear) {
            Button("清空", role: .destructive) { model.clearFile() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将截断磁盘上的「\(model.fileName)」，已写入的内容无法恢复。")
        }
    }
}

/// Renders with `NSTextView` (via `NSViewRepresentable`) rather than a SwiftUI List,
/// per design.md §4, for large-text performance.
///
/// New output is applied as an edit to the end of the text storage (`LogTailModel.changeStart`)
/// instead of replacing the whole string: re-assigning up to 2 MB ten times a second made
/// AppKit lay the entire log out again on every update of a chatty service.
struct LogTextView: NSViewRepresentable {
    let model: LogTailModel
    var query: String = ""
    /// Passed explicitly so every new revision reaches `updateNSView`.
    let revision: Int
    var fontSize: Double = 11

    final class Coordinator {
        var revision = -1
        var query = ""
        var fontSize = 0.0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isRichText = false
        // ⌘F finds within the loaded text, independent of the line filter above.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let coordinator = context.coordinator
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if coordinator.fontSize != fontSize {
            textView.font = font
            // `font` only applies to new text, so restyle what is already laid out.
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
            coordinator.fontSize = fontSize
        }
        let current = model.revision
        guard coordinator.revision != current || coordinator.query != query else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        let wasAtBottom = isScrolledToBottom(nsView)
        storage.beginEditing()
        if query.isEmpty, coordinator.query.isEmpty,
           let from = model.changeStart(since: coordinator.revision), from <= storage.length {
            let tail = NSAttributedString(string: model.text(fromUTF16: from), attributes: attributes)
            storage.replaceCharacters(in: NSRange(location: from, length: storage.length - from), with: tail)
        } else {
            storage.setAttributedString(NSAttributedString(string: model.displayText(matching: query), attributes: attributes))
        }
        storage.endEditing()
        coordinator.revision = current
        coordinator.query = query
        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        let visibleMaxY = scrollView.contentView.bounds.maxY
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        return documentHeight - visibleMaxY < 40
    }
}
