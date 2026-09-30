import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Loads the tail of a log file and follows appends via `DispatchSource.makeFileSystemObjectSource`
/// (design.md §4: only the last ~2 MB / 5000 lines are ever held in memory).
@MainActor
final class LogTailModel: ObservableObject {
    private let path: String
    @Published private var lines: [String] = []
    @Published var sizeDescription: String = ""

    private var source: DispatchSourceFileSystemObject?
    private var lastInode: UInt64?
    private var pendingFSWork: DispatchWorkItem?

    static let maxBytes: Int64 = 2 * 1024 * 1024
    static let maxLines = 5000

    init(path: String) {
        self.path = path
    }

    func start() {
        loadTail()
        resumeFollowing()
    }

    func stop() {
        pendingFSWork?.cancel()
        pendingFSWork = nil
        source?.cancel()
        source = nil
    }

    func resumeFollowing() {
        guard source == nil else { return }
        let newFD = open(path, O_EVTONLY)
        guard newFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: newFD, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            self?.handleFSEvent()
        }
        // Captures `newFD` itself rather than reading `self.fd` back — that mutable property
        // used to be shared across every `resumeFollowing`/`pauseFollowing` cycle, so a quick
        // pause-then-resume left this cancel handler closing the *new* source's fd instead of
        // its own once it eventually fired, and `stop()`'s own manual `close(fd)` raced it for
        // the same descriptor (Apple's own guidance is that only a source's cancel handler
        // should close the descriptor it was created with, R13).
        src.setCancelHandler {
            close(newFD)
        }
        src.resume()
        source = src
    }

    func pauseFollowing() {
        source?.cancel()
        source = nil
    }

    func clearFile() {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.truncateFile(atOffset: 0)
        try? handle.close()
        loadTail()
    }

    func displayText(matching query: String) -> String {
        guard !query.isEmpty else { return lines.joined(separator: "\n") }
        return lines.filter { $0.localizedCaseInsensitiveContains(query) }.joined(separator: "\n")
    }

    /// A chatty service's file-system events can fire dozens of times a second; each one used
    /// to trigger `displayText(matching:)` in `LogViewerView.body` immediately, which joins up
    /// to 5000 lines into a string and diffs it against the full `NSTextView` contents — cheap
    /// once, not at that rate (design.md §4, ex-F18). Coalescing to one pass per ~100ms caps
    /// the rebuild rate without changing what ends up on screen.
    ///
    /// This only schedules a new pass when none is already pending — it used to cancel and
    /// reschedule on every single event, which is a debounce, not a throttle: output arriving
    /// faster than once every 100ms kept pushing the deadline back and the view could go
    /// arbitrarily long without a single refresh (R13).
    private func handleFSEvent() {
        guard pendingFSWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingFSWork = nil
            self?.processFSEvent()
        }
        pendingFSWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func processFSEvent() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = attrs[.systemFileNumber] as? UInt64 else {
            loadTail()
            return
        }
        if let lastInode, lastInode != inode {
            // Rotated (or recreated); reload from scratch.
            loadTail()
            return
        }
        appendNewData()
    }

    private var readOffset: UInt64 = 0

    private func loadTail() {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            lines = ["(日志文件尚不存在)"]
            sizeDescription = "0 B"
            return
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(Self.maxBytes) ? size - UInt64(Self.maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        var text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        var allLines = text.components(separatedBy: "\n")
        if allLines.count > Self.maxLines {
            allLines = Array(allLines.suffix(Self.maxLines))
        }
        lines = allLines
        readOffset = size
        sizeDescription = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            lastInode = attrs[.systemFileNumber] as? UInt64
        }
    }

    private func appendNewData() {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < readOffset {
            // Truncated (copytruncate rotation) — restart from the top.
            loadTail()
            return
        }
        // A paused viewer resuming into a burst of output — or any gap this large — should be
        // capped the same way the initial load caps it, rather than reading the whole thing
        // into memory in one `readDataToEndOfFile()` just because it happened to arrive as a
        // single follow-up event (R13).
        guard size - readOffset <= UInt64(Self.maxBytes) else {
            loadTail()
            return
        }
        try? handle.seek(toOffset: readOffset)
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        // Advances by what was actually read, not by the size observed before reading it — the
        // file can grow between that `seekToEnd()` and this read, and stamping `readOffset` to
        // the earlier, smaller size used to mean the bytes appended in between got queued up to
        // be read (and displayed) a second time on the next event (R13).
        readOffset += UInt64(data.count)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var newLines = text.components(separatedBy: "\n")
        if newLines.last == "" { newLines.removeLast() }
        lines.append(contentsOf: newLines)
        if lines.count > Self.maxLines {
            lines = Array(lines.suffix(Self.maxLines))
        }
        sizeDescription = ByteCountFormatter.string(fromByteCount: Int64(readOffset), countStyle: .file)
    }
}
