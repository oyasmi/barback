# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Barback is a macOS (13+, Apple Silicon) menu-bar app that supervises long-running background
processes (auto-restart, crash-storm protection) and one-shot commands, similar in spirit to
`supervisor` but as a single-process, zero-dependency, no-daemon app. Swift 6, AppKit/SwiftUI,
SQLite for persistence. Full narrative docs: `docs/design.md` (architecture, state machines, data
model) and `docs/requirements.md` (scope/requirements). Code comments frequently cite section
numbers from `design.md` (e.g. "design.md §3.3") and historical finding IDs (e.g. "ex-F21") from
past code-review passes — these refer to bugs already fixed; treat them as rationale for why the
code looks the way it does, not open issues.

## Commands

```bash
make build      # swift build (debug) — use this while developing
make test       # swift test — full suite: pure unit tests + real-process integration tests
make run         # swift run BarbackApp — debug run, no .app bundle (no system notifications)
make             # Scripts/build.sh + Scripts/package.sh → dist/Barback.app, dist/Barback.dmg
make clean       # rm -rf .build dist
```

Run a single test target or case directly with SwiftPM, e.g.:
```bash
swift test --filter ServiceStateMachineTests
swift test --filter ServiceStateMachineTests/testNameHere
```

There are three test targets, each with a different cost/purpose:
- `CoreTests` — pure state-machine/util unit tests, no real processes, fast.
- `ProcessTests` — spawns real processes via `Fixtures/testchild` to test `ProcessHost`/exit
  detection end to end.
- `IntegrationTests` — end-to-end scenarios like crash recovery across a simulated Barback restart.

`Fixtures/testchild` is a controllable child executable (flags: `--exit-after`, `--exit-code`,
`--ignore-term`, `--spawn-children`, `--spam-stdout`, `--alloc`) used by `ProcessTests`/
`IntegrationTests` to simulate crashing, signal-ignoring, or resource-hungry managed processes.

Packaging (`Scripts/build.sh`, `Scripts/package.sh`, `Scripts/sign-notarize.sh`) is arm64-only by
default; `ARCHS="arm64 x86_64" Scripts/build.sh` builds Universal 2. Signing/notarizing requires
`DEVELOPER_ID_APPLICATION` in the environment — not something to invoke incidentally.

## Architecture

Two targets, strictly layered:

- **`Sources/BarbackCore`** — the supervision kernel. No AppKit/SwiftUI import, no UI dependency.
  Runs entirely on one serial dispatch queue (`barback.core`) that owns all mutable state — this
  is what makes it lock-free and lets the state machines be tested exhaustively without a UI.
  After any state change it publishes an immutable snapshot to the main thread; it never reads
  state back from the UI.
- **`Sources/BarbackApp`** — UI layer (menu-bar left-click panel, right-click menu, config window,
  log viewer, history window, events window, preferences, supervisor-import sheet). Only ever
  reads published snapshots and posts commands into the core queue; never touches core state
  directly.

Key components inside `BarbackCore`:

| Component | Role |
| --- | --- |
| `StateMachine/ServiceStateMachine` | Pure reducer for long-running services: `(runtime, event, config) -> (runtime, [action])`. No I/O — see design.md §3.3 for the full state diagram (STOPPED/STARTING/RUNNING/BACKOFF/STOPPING/EXITED/FATAL). |
| `StateMachine/OneshotStateMachine` | Same pattern for one-shot commands (IDLE/RUNNING/SUCCEEDED/FAILED/TIMEOUT/CANCELLED — no autorestart/backoff). |
| `Process/ProcessHost` | Wraps `posix_spawn` with `POSIX_SPAWN_SETSID` (session/process-group control, required for `stopAsGroup`/`killAsGroup`). Deliberately not Foundation's `Process`, which can't set pgid. |
| `Process/ExitWatcher` | `kqueue EVFILT_PROC/NOTE_EXIT` + `waitpid(WNOHANG)` — event-driven exit detection, zero polling, also works for adopted orphans after a crash-recovery. |
| `Process/ProcSampler` | On-demand CPU/RSS sampling, only while the panel is open. |
| `Log/LogManager` | Child stdout/stderr fds go straight to log files (never through Barback's own process) with size-based rotation via copy-then-truncate (rename would leave the child writing to the old inode). |
| `Store/Store` + `Store/Schema` | Single SQLite file (WAL mode) for program config, live-process snapshot, run history, and events. `PRAGMA user_version` drives schema migrations (`Schema.currentVersion`). All access must happen on the core queue — `Store` does not hop queues itself. Recovers from a corrupt DB by restoring the latest JSON config backup (see `Store.restoredProgramCount`). |
| `Import/SupervisorImporter` | Parses pasted `supervisor` `[program:x]` INI text into a field-mapping preview (see README's mapping table) for non-destructive migration. |

The reducers (`ServiceStateMachine.reduce`, `OneshotStateMachine`) are the core abstraction to
understand before touching supervision behavior: they take `(runtime state, event, Program config)`
and return `(new runtime, [ServiceAction])`, and never perform I/O themselves — `Supervisor` (`Sources/BarbackApp/Supervisor.swift`, despite
living in the app target it only orchestrates the core queue) executes the returned actions
against real processes/timers/the store. When changing restart,
backoff, or crash-storm logic, edit the reducer and its test in
`Tests/CoreTests/ServiceStateMachineTests.swift`, then re-derive the state diagram in
`docs/design.md` §3.3 if the transition table changes.

Process identity (pid + `proc_pidinfo` start time) is captured immediately after `posix_spawn`
and used everywhere a pid is checked, specifically to avoid mistaking a reused pid for a still-live
managed process (relevant after sleep/wake and crash-recovery adoption).

Timers use `DispatchSourceTimer` with generous leeway (≥10% or ≥1s) to let the kernel coalesce
wakeups — part of the "zero overhead at idle" constraint (design.md §1).

## Design constraints that shape review/PRs

From design.md §1, in priority order when trade-offs conflict:
1. Simplicity — single process, single DB, no daemon, no IPC, no external config file.
2. Zero overhead at idle — no polling; the only periodic tasks in the whole app are two 300s
   (30s leeway) timers — the log-size check and the liveness reconcile safety net — both
   loose enough for the kernel to coalesce freely. New periodic timers/polling loops need
   strong justification.
3. Predictable semantics — any field shared with `supervisor` must mean the same thing.
4. Fault isolation — a managed process's failure must never affect Barback or other managed
   processes.

Config (programs, autostart/autorestart, log paths, etc.) is only ever mutated through the GUI —
there is no CLI and no human-editable config file; don't add code paths that write config outside
`Store`.

## Git

- Write good commit messages: a concise imperative subject line (e.g. `feat: add proxy routing for LLM requests`), optionally followed by a blank line and a body that explains *why* the change was made. Match the existing conventional-commit style (`feat:`, `fix:`, `chore:`, `ci:`, `docs:`, etc.).
- **Never add a `Co-Authored-By:` trailer** (or any similar signature) to commit messages.
