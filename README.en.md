# Barback

[中文](README.md) · [Apache License 2.0](LICENSE)

Barback manages local background services and one-shot commands, with start/stop controls, automatic restarts, logs, and execution history.

| Platform | Status | Documentation |
| --- | --- | --- |
| macOS | Implemented in Swift 6, AppKit and SwiftUI; macOS 13+ | [Usage and build](macos/README.en.md) |
| Windows | C# / .NET 10 LTS / WPF; v0.3.2.0 x64 Release build and unsigned MSIX verified; signing and real-device release validation remain | [Build and validation (Chinese)](windows/README.md) |

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

Build, test, and package Windows:

```powershell
cd windows
./scripts/build.ps1 -Architecture x64 -Configuration Release
./scripts/test.ps1
./scripts/package.ps1 -Architecture x64 -Version 0.3.2.0
```

The default x64 MSIX is written to `windows/dist/Barback-0.3.2.0-x64.msix` and is currently about 15.7 MB. It requires the .NET 10 Desktop Runtime on the target machine. Without a certificate, the package is unsigned; signing and real-device validation are still required for release. Add `-SelfContained` when the .NET runtime must be bundled, at the cost of a much larger package.
