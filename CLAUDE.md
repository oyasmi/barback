# Repository layout

Barback has separate native platform implementations:

- `macos/`: existing Swift app. Read `macos/CLAUDE.md` for its architecture and development conventions. Run SwiftPM and packaging commands from `macos/`; root Make targets forward there.
- `windows/`: C#/.NET 10/WPF development candidate. Read `windows/README.md` and its linked design documents before implementing the .NET app. Implementation and validation evidence live in `windows/docs/implementation-status.md`; real Windows and ARM64 release gates remain mandatory.

Keep platform-specific code, tests, resources and documentation in their platform directory. Keep shared repository metadata, the license and GitHub Actions workflows at the root. macOS constraints do not automatically apply to the Windows implementation; the Windows design explicitly records platform differences.
