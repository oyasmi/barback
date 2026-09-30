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
                    .onChange(of: isFollowing) { newValue in
                        if newValue { model.resumeFollowing() } else { model.pauseFollowing() }
                    }
                TextField("搜索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                Button("清空") { model.clearFile() }
                Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                Button("外部打开") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
            .padding(8)
            Divider()
            LogTextView(text: model.displayText(matching: searchText), fontSize: fontSize)
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
    }
}

/// Renders with `NSTextView` (via `NSViewRepresentable`) rather than a SwiftUI List,
/// per design.md §4, for large-text performance.
struct LogTextView: NSViewRepresentable {
    let text: String
    var fontSize: Double = 11

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.font?.pointSize != CGFloat(fontSize) {
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            textView.font = font
            // `font` only applies to new text, so restyle what is already laid out.
            textView.textStorage?.addAttribute(
                .font, value: font, range: NSRange(location: 0, length: textView.string.utf16.count)
            )
        }
        if textView.string != text {
            let wasAtBottom = isScrolledToBottom(nsView)
            textView.string = text
            if wasAtBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        let visibleMaxY = scrollView.contentView.bounds.maxY
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        return documentHeight - visibleMaxY < 40
    }
}
