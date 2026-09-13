# Barback

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20(Apple%20Silicon)-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)

> Manage background services and everyday commands on macOS with supervisor's semantics — all from the menu bar.

[中文](README.md) · English

Barback is a menu-bar-resident process manager. Hand it the local services, tunnels, inference servers and sync daemons that live on your Mac: it restarts them when they die, shows their state at a glance, and puts "restart" and "show me the log" two clicks away. The name is a bartender's assistant (a barback) — and a pun on the macOS **Menu Bar**.

- **One process** — no daemon, no IPC, no config file to hand-edit. Quit Barback and every managed process goes with it.
- **No third-party dependencies** — Swift 6 with AppKit/SwiftUI, around 1 MB of binary.
- **Free when idle** — process exits arrive as kqueue events rather than polling, and CPU/memory sampling happens only while the panel is open.

## Features

**Services** (long-running, with supervisor's supervision semantics under the same field names)

- `autostart` on login, `autorestart` (never / unexpected / always)
- `startSeconds` liveness threshold, `startRetries` cap, exponential backoff, and restart-storm protection (enters `FATAL` and stops retrying)
- Configurable stop sequence — `stopSignal` / `stopWaitSeconds` / `stopAsGroup` / `killAsGroup` — escalating to `SIGKILL` on timeout
- Crash adoption: if Barback itself is `kill -9`'d, the next launch reclaims child processes that are still running (verified by PID *and* process start time, so a recycled PID is never mistaken for the original)
- Reconciles real process liveness after the machine wakes from sleep

**One-shot commands** (triggered by hand, run to completion)

- Timeout kill, confirmation prompt for dangerous commands, optional concurrent runs
- Every run keeps its output and a record (time / duration / exit code / outcome), trimmed to a per-command limit

**Everything else**

- Child stdout/stderr is written straight to disk (never through Barback) and rotated by size; the built-in log viewer follows the tail and highlights searches
- Migration from supervisor: paste `[program:x]` INI text, review the field mapping, import the entries you pick
- Event log and system notifications (service failure, unexpected restart, command finished), with a debounce window
- Launch at login via `SMAppService`

## The menu bar panel

Left-click is the most-used surface in the app, so every routine action sits directly on the row — there are no submenus:

```
┌─ Left-click panel ─────────────────────────────────────────┐
│ ●1 running  ○2 stopped  ⚠1 failed  ◌1 busy            ⚙  │
│ 🔍 Search                                  (appears at > 8)│
├────────────────────────────────────────────────────────────┤
│ Services 4                                                 │
│ ▎● nslocal        running          [■ Stop ] [↻] [📄] [⌄] │
│    PID 4821 · up 2d 3h · CPU 0.3% · 48.0 MB                │
│ ▎◑ api-server     retry 2/3        [■ Stop ] [↻] [📄] [⌄] │
│    retrying in 12s · last exit today 22:26 · code 1        │
│    ▁▁▁▁▁▁▁▁▃▃▃▃▃▃▃▃▃▃▃▃                                   │
│ ▎⚠ tunnel         start failed     [▶ Start] [↻] [📄] [⌄] │
│    3 retries · last exit today 22:21 · code 127            │
│    ⚠ Auto-retry stopped, needs attention        Clear      │
│ One-shot commands 1                                        │
│ ▎✓ backup-db      succeeded        [▶ Run  ] [📄] [🕑] [⌄] │
│    last today 20:27 · took 3.4s · 27 runs                  │
├────────────────────────────────────────────────────────────┤
│ [▶ Start all]   [■ Stop all]   [↻ Restart all]             │
└────────────────────────────────────────────────────────────┘
```

- The primary button follows the state: **Stop** while running, **Start** while stopped, **Force kill** (with confirmation) while a stop is in flight.
- Click anywhere on a row to expand a drawer with the command, working directory, log path, config summary, and *Reveal in Finder* / *Copy PID* / *Edit configuration*.
- State is carried by shape and wording as well as colour, never colour alone; failure states offer the remedy as a button you can press right there.
- **Right-click** (or Control-click) opens Barback's own menu — configuration window, run history, event log, preferences, paste-import, quit — with no overlap with the left-click panel.

> The interface is currently Simplified Chinese only; English localization is planned.

## Install

Requires **macOS 13+ on Apple Silicon** (`ARCHS="arm64 x86_64" Scripts/build.sh` produces a Universal 2 build) and the Xcode command line tools (Swift 6).

```bash
git clone https://github.com/oyasmi/barback.git && cd barback
make                             # builds dist/Barback.app and dist/Barback.dmg
cp -R dist/Barback.app /Applications/
```

A self-built bundle is unsigned, so Gatekeeper blocks the first launch: right-click it in Finder → *Open* → *Open*. With a Developer ID:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: ..." make sign   # sign + notarize
```

First launch walks you through the login item and notification permissions and adding your first program. Barback is an `LSUIElement` app — no Dock icon, no main window, just the menu bar.

## Usage

| What you want | Where it is |
| --- | --- |
| Start / stop / restart a service | Left-click → the row's primary button |
| Read a program's log | Left-click → 📄 on the row |
| See PID / uptime / CPU / memory | Left-click — the metrics are on the row, refreshed every second |
| See the command, directory, log path | Left-click → click the row to expand its drawer |
| Add, edit or delete a program | Right-click → *Open configuration window* (⌘,) |
| Migrate from supervisor | Right-click → *Paste-import from supervisor* |

### Migrating from supervisor

Paste one or more `[program:name]` INI sections; Barback parses them and shows a mapping preview (what will be imported, what cannot be mapped and why) before you pick what to bring over. Shared field names keep their meaning:

| supervisor | Barback | Notes |
| --- | --- | --- |
| `command` | `command` | An `sh -c` prefix is turned into `use_shell` automatically |
| `autostart` | `autostart` | **Always forced to false on import**, so nothing races a supervisord that is still running |
| `autorestart` | `autorestart` | `true→always` / `false→never` / `unexpected→unexpected` |
| `exitcodes` `startsecs` `startretries` | same names | — |
| `stopsignal` `stopwaitsecs` `stopasgroup` `killasgroup` | same names | — |
| `stdout_logfile` `stderr_logfile` `redirect_stderr` | `log_path` `log_stderr_path` `log_merge_stderr` | `AUTO`/`NONE` become the default path / discard |
| `user` `numprocs` `process_name` `umask` … | — | Listed as unmappable, with the reason |

The import is non-destructive: no supervisor file is read or written. Once imported, `supervisorctl stop all` and disable supervisord before starting anything in Barback.

## Files and data

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/Barback/barback.db` | Config, run records, events (SQLite; edited only through the GUI) |
| `~/Library/Application Support/Barback/backups/` | Automatic config backups |
| `~/Library/Logs/Barback/programs/` | Service logs (size-rotated) |
| `~/Library/Logs/Barback/runs/` | Per-run output of one-shot commands |
| `~/Library/Logs/Barback/barback.log` | Barback's own log |

## Building from source

```bash
make                             # default: build dist/Barback.app and dist/Barback.dmg
make build                       # debug build (lands in .build/debug/BarbackApp)
make test                        # full suite (pure unit tests + real-process integration tests)
make run                         # run the debug build directly (no .app bundle: no notifications)
make clean                       # remove .build and dist
```

Packaged output always goes to `dist/` (git-ignored); `.build/` is just SwiftPM's build cache.

### Layout

```
Sources/BarbackCore    Supervision core, no UI: state machines, process control, SQLite store, log rotation, supervisor import
Sources/BarbackApp     UI: menu bar panel and app menu, configuration window, log viewer, run history, event log, preferences
Sources/CSQLite        modulemap shim for the system libsqlite3
Fixtures/testchild     A test child process with controllable behaviour, used by the process integration tests
Tests/                 CoreTests pure units · ProcessTests real processes · IntegrationTests crash recovery and other end-to-end cases
```

The core runs on a single serial queue, imports neither AppKit nor SwiftUI, and publishes immutable snapshots to the main thread after every change — which is what lets the state machines be tested exhaustively without a UI.

## Known limitations

- Running outside an `.app` bundle (e.g. `make run`) skips system notifications: `UNUserNotificationCenter` needs a real bundle identity.
- No root/system-level services, no remote management, no scheduled jobs (that is launchd's job), no interactive processes that need a TTY.
- No command line client: that would need IPC the single-process design deliberately avoids.
- Further open questions are listed in the [design document](docs/design.md) §9.

## Documentation

The full documents are in Simplified Chinese:

- [Requirements](docs/requirements.md) — positioning, scope, user journeys, itemized requirements
- [Design](docs/design.md) — architecture, state machines, data model, GUI, packaging and test strategy

## License

[Apache License 2.0](LICENSE) © 2026 oyasmi
