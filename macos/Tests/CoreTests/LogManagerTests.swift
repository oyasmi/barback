import Foundation
import Testing
@testable import BarbackCore

struct LogManagerTests {
    // ex-F33: an explicit `~`-prefixed path must resolve to the same absolute path `open()`
    // will actually use — otherwise validation, the log viewer, and the real spawn path can
    // each disagree about what "the log file" even is.
    @Test func serviceLogPathsExpandsTilde() {
        let paths = LogManager.serviceLogPaths(name: "svc", logsDir: "/tmp/barback-logs", mergeStderr: true, explicitOutPath: "~/barback-test.log", explicitErrPath: nil)
        #expect(!paths.out.hasPrefix("~"))
        #expect(paths.out == PathUtil.expandTilde("~/barback-test.log"))
    }

    // ex-F33: an explicit path's parent directory used to only ever exist if the user had
    // created it by hand first — `openServiceLogs` must create it the same way it always has
    // for the default `programs/` directory.
    @Test func openServiceLogsCreatesExplicitParentDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let explicitPath = dir.appendingPathComponent("nested/deep/svc.log").path
        let fds = try LogManager.openServiceLogs(name: "svc", logsDir: "/tmp/unused", mergeStderr: true, explicitOutPath: explicitPath, explicitErrPath: nil)
        defer { LogManager.closeFDs(fds) }
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: explicitPath, isDirectory: &isDir))
        #expect(!isDir.boolValue)
    }
}
