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
    private var fd: Int32 = -1
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
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    func resumeFollowing() {
        guard source == nil else { return }
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            self?.handleFSEvent()
        }
        src.setCancelHandler { [weak self] in
            if let self, self.fd >= 0 { close(self.fd); self.fd = -1 }
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
    private func handleFSEvent() {
        pendingFSWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.processFSEvent() }
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
        try? handle.seek(toOffset: readOffset)
        let data = handle.readDataToEndOfFile()
        readOffset = size
        guard !data.isEmpty else { return }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var newLines = text.components(separatedBy: "\n")
        if newLines.last == "" { newLines.removeLast() }
        lines.append(contentsOf: newLines)
        if lines.count > Self.maxLines {
            lines = Array(lines.suffix(Self.maxLines))
        }
        sizeDescription = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
