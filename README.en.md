# Codex Status Bar

[中文](README.md)

![Full-screen completion overlay](Docs/completion-overlay.png)

A native macOS menu bar utility for monitoring local Codex task activity and the weekly quota.

> This is an independent local utility, not an official OpenAI product.

## Features

- Refreshes task activity every three seconds from the local Codex thread index and lifecycle events, including concurrent and cross-day tasks.
- Hover over the menu bar item for about 0.3 seconds to open the menu. Move the pointer directly into the menu to use it, or away from both the item and menu to close it.
- Lists each user conversation independently as **Working**, **Completed**, or **Idle**. Internal subagents are excluded.
- Click anywhere in a task row to open the corresponding local conversation in the Codex desktop app.
- Shows tasks as completed for up to 30 minutes. When Codex marks the result as read, the next refresh marks the task idle. Idle tasks disappear once more than two hours have passed since the last activity, including the time shown as completed.
- Shows a full-screen completion overlay with a high-resolution character and live frosted-glass background on the display containing the pointer.
- Questions from `request_user_input` or `request_user_input_async` also trigger an overlay and mark the task as waiting for input. A reply resumes the working state; ordinary progress messages do not trigger alerts.
- Toggle overlays with “全屏提醒（完成 / 等待回复）” in the menu. The setting persists across restarts; turning it off fades out the current overlay and clears queued overlays.
- Choose an animated GIF or static image with “更换提示图片…”. The file is copied into local Application Support and retained across restarts. Preview the overlay from the menu. GIF playback stops when the overlay is hidden.
- Images are centered. GIFs fit within a 600-by-600-point display area; static images are never enlarged beyond their original pixel dimensions. The surrounding area retains the full-screen frosted-glass effect.
- Completion events are deduplicated by conversation and timestamp. Events from before launch are ignored, and completions received during an overlay are merged into it instead of queued for later.
- Fades in over 0.8 seconds. Keyboard input, mouse movement, clicks, or scrolling dismiss the overlay; it can finish disappearing after one second and otherwise stays for at most one minute.
- Refreshes quota data every 60 seconds. The menu bar and expanded menu show the weekly quota (for example, `周 65%`). Task rows show the Codex conversation title after each activity label.

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

Download `Codex.Status.zip` from the [v0.1.0 Release](https://github.com/Universeeeeeee/codex-status-bar/releases/tag/v0.1.0), unzip it, then move `Codex Status.app` to Applications and open it.

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

- When an older Codex version provides no read receipts, completed tasks become idle after 30 minutes.
- Weekly quota availability depends on the current Codex app-server response. The app displays `--` when that window is absent.
- macOS does not expose a public API for the exact combined width of all menu bar extras. The app detects truncation of its own title but cannot reliably tell when the system entirely moves the item into overflow.

## License

This project is licensed under the [MIT License](LICENSE). Commercial use, modification, and redistribution are permitted, provided that copies or substantial portions retain the copyright and license notice.
