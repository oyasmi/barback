# Barback

[中文](README.md) · [Apache License 2.0](LICENSE)

Barback manages local background services and one-shot commands, with start/stop controls, automatic restarts, logs, and execution history.

| Platform | Status | Documentation |
| --- | --- | --- |
| macOS | Implemented in Swift 6, AppKit and SwiftUI; macOS 13+ | [Usage and build](macos/README.en.md) |
| Windows | Development candidate: C# / .NET 10 LTS / WPF source; real Windows release validation pending | [Build and validation (Chinese)](windows/README.md) |

Platform implementations live in `macos/` and `windows/`. The repository license and GitHub workflows remain at the root. Each platform uses native lifecycle and interaction conventions; feature and configuration parity are not guaranteed.

Build on macOS:

```bash
git clone https://github.com/oyasmi/barback.git
cd barback/macos
make build
make test
make
```

Root-level Make targets forward to `macos/`. Build artifacts are now in `macos/dist/`; run SwiftPM commands from `macos/`.
