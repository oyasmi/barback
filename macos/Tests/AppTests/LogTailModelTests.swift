import Foundation
import Testing
@testable import BarbackApp

@MainActor
struct LogTailModelTests {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func waitForText(_ text: String, in model: LogTailModel) async throws {
        for _ in 0..<100 {
            if model.text == text { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(model.text == text)
    }

    @Test func resumingReadsQuietFileImmediately() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("out.log")
        try "first\n".write(to: file, atomically: false, encoding: .utf8)
        let model = LogTailModel(path: file.path)
        model.start()
        defer { model.stop() }
        model.pauseFollowing()
        try append("second\n", to: file)
        #expect(model.text == "first\n")
        model.resumeFollowing()
        #expect(model.text == "first\nsecond\n")
        #expect(model.matchingLineCount("SECOND") == 1)
    }

    @Test func rotationRearmsWatcherForSubsequentWrites() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("out.log")
        try "old\n".write(to: file, atomically: false, encoding: .utf8)
        let model = LogTailModel(path: file.path)
        model.start()
        defer { model.stop() }
        try FileManager.default.moveItem(at: file, to: dir.appendingPathComponent("out.log.1"))
        try "new\n".write(to: file, atomically: false, encoding: .utf8)
        try await waitForText("new\n", in: model)
        try append("after rotation\n", to: file)
        try await waitForText("new\nafter rotation\n", in: model)
    }

    @Test func resumingDetectsSameLengthRewrite() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("out.log")
        try "old\n".write(to: file, atomically: false, encoding: .utf8)
        let model = LogTailModel(path: file.path)
        model.start()
        defer { model.stop() }
        model.pauseFollowing()
        try "new\n".write(to: file, atomically: false, encoding: .utf8)
        model.resumeFollowing()
        #expect(model.text == "new\n")
    }

    @Test func filteringReportsOnlyTheLoadedTail() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("out.log")
        let output = "older-only\n" + Array(repeating: "recent\n", count: 6000).joined()
        try output.write(to: file, atomically: false, encoding: .utf8)
        let model = LogTailModel(path: file.path)
        model.start()
        defer { model.stop() }
        #expect(model.isTailTruncated)
        #expect(model.matchingLineCount("older-only") == 0)
        #expect(model.matchingLineCount("recent") == LogTailModel.maxLines)
    }

    @Test func absentLogAppearsWhenNestedDirectoryIsCreated() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("new/run/out.log")
        let model = LogTailModel(path: file.path)
        model.start()
        defer { model.stop() }
        #expect(!model.fileAvailable)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "created\n".write(to: file, atomically: false, encoding: .utf8)
        try await waitForText("created\n", in: model)
        #expect(model.fileAvailable)
    }
}
