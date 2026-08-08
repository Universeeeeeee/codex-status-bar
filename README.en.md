# Codex Status Bar

[中文](README.md)

A native macOS menu bar utility for monitoring local Codex task activity and the weekly quota.

> This is an independent local utility, not an official OpenAI product.

## Features

- Refreshes task activity every three seconds from the local Codex thread index and lifecycle events, including concurrent and cross-day tasks.
- Lists each user conversation independently as **Working**, **Completed**, or **Idle**. Internal subagents are excluded.
- Keeps completed tasks for ten minutes, then removes idle tasks after five hours.
- Shows a full-screen completion overlay with a high-resolution character and live frosted-glass background on the display containing the pointer.
- Fades in over 0.8 seconds. Keyboard input, mouse movement, clicks, or scrolling dismiss the overlay; it can finish disappearing after one second and otherwise stays for at most one minute.
- Refreshes the weekly quota every 60 seconds. When the menu bar truncates the status title, the menu reports it and the tooltip retains the full text.

## Architecture

```text
Sources/CodexStatusBar/
├── Core.*                 Activity rules, session parsing, quota parsing, snapshot merging
├── AppServerClient.*      JSON-RPC client for Codex app-server
├── CompletionOverlay.*    Full-screen frosted completion overlay and input dismissal
├── AppDelegate.*          Refresh scheduling, menu rendering, completion transitions
└── main.m                 Application entry point and command-line diagnostics
```

`Core` is independent of AppKit and contains the testable data rules. `AppDelegate` coordinates the user interface and refresh timers. Partial quota responses are merged with the last valid snapshot, so an omitted field does not erase an existing value.

## Requirements

- macOS 13 or later
- Codex Desktop or Codex CLI installed
- macOS Command Line Tools

Xcode and third-party libraries are not required.

## Quick Install

Download `Codex Status.zip` from the [v0.1.0 Release](https://github.com/Universeeeeeee/codex-status-bar/releases/tag/v0.1.0), unzip it, then move `Codex Status.app` to Applications and open it.

The app is ad-hoc signed for personal use. If macOS blocks the first launch, Control-click the app in Finder and choose Open, or approve it in System Settings > Privacy & Security.

## Build and Run

```bash
make test
make app
make archive
make run
```

The app bundle is produced at `outputs/Codex Status.app`; `make archive` produces the distributable `outputs/Codex Status.zip`. It is locally ad-hoc signed for personal use and local distribution.

## Diagnostics

```bash
.build/CodexStatusBarTests --probe-sessions
.build/CodexStatusBarTests --test-overlay
```

The first command prints detected user tasks. The second command triggers the completion overlay.

## Data and Privacy

The utility reads the local thread index and lifecycle events under `~/.codex`, then retrieves quota information from the local `codex app-server`. It does not upload session contents or store account credentials.

## Known Limitations

- Weekly quota availability depends on the current Codex app-server response. The app displays `--` when that window is absent.
- macOS does not expose a public API for the exact combined width of all menu bar extras. The app detects truncation of its own title but cannot reliably tell when the system entirely moves the item into overflow.

## License

No license has been selected yet. Add one before publishing a public repository.
