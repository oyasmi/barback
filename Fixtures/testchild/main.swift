import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Controllable child process for process-management integration tests
// (design.md §8.4): --exit-after, --exit-code, --ignore-term, --spawn-children,
// --spam-stdout, --alloc.

var exitAfter: Double?
var exitCode: Int32 = 0
var ignoreTerm = false
var spawnChildren = 0
var spamStdout = false
var allocMB = 0

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let arg = args[i]
    switch arg {
    case "--exit-after":
        i += 1; exitAfter = Double(args[i])
    case "--exit-code":
        i += 1; exitCode = Int32(args[i]) ?? 0
    case "--ignore-term":
        ignoreTerm = true
    case "--spawn-children":
        i += 1; spawnChildren = Int(args[i]) ?? 0
    case "--spam-stdout":
        spamStdout = true
    case "--alloc":
        i += 1; allocMB = Int(args[i]) ?? 0
    default:
        break
    }
    i += 1
}

if ignoreTerm {
    signal(SIGTERM, SIG_IGN)
}

for _ in 0..<spawnChildren {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 10000"]
    try? p.run()
}

var allocated: [UnsafeMutableRawPointer] = []
if allocMB > 0 {
    let chunk = allocMB * 1024 * 1024
    if let p = malloc(chunk) {
        memset(p, 1, chunk)
        allocated.append(p)
    }
}

let start = Date()
while true {
    if spamStdout {
        print("spam \(Date().timeIntervalSince1970)")
        fflush(stdout)
    }
    if let exitAfter, Date().timeIntervalSince(start) >= exitAfter {
        exit(exitCode)
    }
    usleep(spamStdout ? 1000 : 100_000)
}
