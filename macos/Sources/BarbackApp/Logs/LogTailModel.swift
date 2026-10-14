import Foundation
import Combine
import BarbackCore
#if canImport(Darwin)
import Darwin
#endif

/// Loads the tail of a log file and follows appends via `DispatchSource.makeFileSystemObjectSource`
/// (design.md §4: only the last ~2 MB / 5000 lines are ever held in memory).
@MainActor
final class LogTailModel: ObservableObject {
    private let path: String
    /// Bumped whenever the displayed text changes; views compare it with what they last drew.
    @Published private(set) var revision = 0
    @Published var sizeDescription: String = ""
    @Published private(set) var fileAvailable = false
    @Published var failure: String?
    private(set) var isTailTruncated = false

    /// Completed lines, already cleaned for display (`LogLineAssembler`).
    private var lines: [String] = []
    /// `lines`, each followed by a newline — the part of the display text that only grows.
    private var committed = ""
    private var committedLength = 0
    /// The unfinished last line, shown after `committed` until its newline arrives.
    private var partial = ""
    private var assembler = LogLineAssembler()
    /// Recent revisions and the UTF-16 offset from which each one's text differs from the
    /// previous revision's (`nil` = unrelated text, redraw everything).
    private var edits: [(revision: Int, from: Int?)] = []

    private var source: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var watchedDirectory: String?
    private var watchedDirectoryInode: UInt64?
    private var isFollowing = false
    private var lastInode: UInt64?
    private var pendingFSWork: DispatchWorkItem?
    private var watchGeneration = UUID()

    static let maxBytes: Int64 = 2 * 1024 * 1024
    static let maxLines = 5000
    /// Old lines are dropped in batches of this many, so the text view rebuilds once per batch
    /// instead of on every line once the limit is reached — everything else is an append.
    static let trimBatch = 500
    private static let editHistory = 16

    init(path: String) {
        self.path = path
    }

    func start() {
        resumeFollowing()
    }

    func stop() {
        isFollowing = false
        watchGeneration = UUID()
        pendingFSWork?.cancel()
        pendingFSWork = nil
        source?.cancel()
        source = nil
        directorySource?.cancel()
        directorySource = nil
        watchedDirectory = nil
        watchedDirectoryInode = nil
    }

    func resumeFollowing() {
        stop()
        isFollowing = true
        watchDirectory()
        watchFile()
        // Reload immediately, also catching same-length rewrites while updates were paused.
        loadTail()
    }

    private func watchFile() {
        guard isFollowing, source == nil else { return }
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
        stop()
    }

    /// Watch the nearest existing ancestor too, so creation and rename-based rotation can
    /// replace a missing/dead file descriptor without polling while a window is open.
    private func watchDirectory() {
        guard isFollowing else { return }
        var directory = (path as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        while !directory.isEmpty {
            if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue { break }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { return }
            directory = parent
        }
        let inode = (try? FileManager.default.attributesOfItem(atPath: directory)[.systemFileNumber]) as? UInt64
        guard !directory.isEmpty, directory != watchedDirectory || inode != watchedDirectoryInode else { return }
        directorySource?.cancel()
        directorySource = nil
        watchedDirectory = nil
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        watcher.setEventHandler { [weak self] in self?.handleFSEvent() }
        watcher.setCancelHandler { close(fd) }
        watchedDirectory = directory
        watchedDirectoryInode = inode
        directorySource = watcher
        watcher.resume()
    }

    /// Truncates the file on disk. Irreversible — callers confirm with the user first.
    func clearFile() {
        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            loadTail()
        } catch {
            failure = error.localizedDescription
        }
    }

    var fileName: String { (path as NSString).lastPathComponent }

    var loadedRangeDescription: String {
        let count = lines.count + (partial.isEmpty || !fileAvailable ? 0 : 1)
        return isTailTruncated
            ? String(localized: "仅显示末尾 \(count) 行，较早内容请外部打开")
            : String(localized: "已加载 \(count) 行")
    }

    func matchingLineCount(_ query: String) -> Int {
        guard fileAvailable else { return 0 }
        return lines.filter { $0.localizedCaseInsensitiveContains(query) }.count
            + (!partial.isEmpty && partial.localizedCaseInsensitiveContains(query) ? 1 : 0)
    }

    /// The whole display text.
    var text: String { committed + partial }

    /// The display text from UTF-16 offset `from` on; pairs with `changeStart(since:)`.
    func text(fromUTF16 from: Int) -> String {
        if from >= committedLength {
            return (partial as NSString).substring(from: min(from - committedLength, (partial as NSString).length))
        }
        return (committed as NSString).substring(from: from) + partial
    }

    /// Where the text first differs from what it was at `revision`, or `nil` when the view
    /// has to redraw everything (a reload, a trim, or a revision too old to reconstruct).
    func changeStart(since applied: Int) -> Int? {
        guard applied < revision, let oldest = edits.first, oldest.revision <= applied + 1 else { return nil }
        var start = Int.max
        for edit in edits where edit.revision > applied {
            guard let from = edit.from else { return nil }
            start = min(start, from)
        }
        return start == Int.max ? nil : start
    }

    func displayText(matching query: String) -> String {
        guard !query.isEmpty else { return text }
        var matches = lines.filter { $0.localizedCaseInsensitiveContains(query) }
        if partial.localizedCaseInsensitiveContains(query) { matches.append(partial) }
        return matches.joined(separator: "\n")
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
        guard isFollowing, pendingFSWork == nil else { return }
        let generation = watchGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.watchGeneration == generation else { return }
            self.pendingFSWork = nil
            self.processFSEvent()
        }
        pendingFSWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func processFSEvent() {
        guard isFollowing else { return }
        watchDirectory()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = attrs[.systemFileNumber] as? UInt64 else {
            source?.cancel()
            source = nil
            lastInode = nil
            loadTail()
            return
        }
        if lastInode != inode {
            // Rotated (or recreated); reload from scratch.
            source?.cancel()
            source = nil
            watchFile()
            loadTail()
            return
        }
        watchFile()
        appendNewData()
    }

    private var readOffset: UInt64 = 0

    private func loadTail() {
        assembler = LogLineAssembler()
        guard let handle = FileHandle(forReadingAtPath: path) else {
            lastInode = nil
            fileAvailable = false
            isTailTruncated = false
            replaceAll(lines: [], partial: String(localized: "(日志文件尚不存在)"))
            readOffset = 0
            sizeDescription = "0 B"
            return
        }
        defer { try? handle.close() }
        fileAvailable = true
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(Self.maxBytes) ? size - UInt64(Self.maxBytes) : 0
        try? handle.seek(toOffset: start)
        var data = handle.readDataToEndOfFile()
        readOffset = start + UInt64(data.count)
        // Starting mid-file means starting mid-line (and maybe mid-character): begin at the
        // first full line instead.
        if start > 0 {
            if let newline = data.firstIndex(of: 0x0A) {
                data = data.subdata(in: data.index(after: newline)..<data.endIndex)
            } else {
                data = Data()
            }
        }
        var loaded = assembler.append(data)
        isTailTruncated = start > 0 || loaded.count > Self.maxLines
        if loaded.count > Self.maxLines {
            loaded = Array(loaded.suffix(Self.maxLines))
        }
        replaceAll(lines: loaded, partial: assembler.partial)
        sizeDescription = ByteCountFormatter.string(fromByteCount: Int64(readOffset), countStyle: .file)
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
        append(lines: assembler.append(data), partial: assembler.partial)
        sizeDescription = ByteCountFormatter.string(fromByteCount: Int64(readOffset), countStyle: .file)
    }

    private func replaceAll(lines newLines: [String], partial newPartial: String) {
        lines = newLines
        committed = newLines.map { $0 + "\n" }.joined()
        committedLength = (committed as NSString).length
        partial = newPartial
        record(from: nil)
    }

    private func append(lines newLines: [String], partial newPartial: String) {
        guard !newLines.isEmpty || newPartial != partial else { return }
        // Everything before the old unfinished line is unchanged.
        let changedFrom = committedLength
        lines.append(contentsOf: newLines)
        if lines.count > Self.maxLines + Self.trimBatch {
            isTailTruncated = true
            replaceAll(lines: Array(lines.suffix(Self.maxLines)), partial: newPartial)
            return
        }
        for line in newLines {
            committed += line
            committed += "\n"
            committedLength += (line as NSString).length + 1
        }
        partial = newPartial
        record(from: changedFrom)
    }

    private func record(from: Int?) {
        revision += 1
        edits.append((revision: revision, from: from))
        if edits.count > Self.editHistory { edits.removeFirst(edits.count - Self.editHistory) }
    }
}
