# Agent Sentinel (MVP)

Agent Sentinel is a native macOS local-first tool for monitoring multiple AI agents running in tmux panes, with fast menu-bar visibility and one-click jump back to the exact pane in iTerm2.

## What Is Included

- Native menu bar app (`SentinelApp`) using SwiftUI + AppKit
- Local monitor daemon (`sentinel-monitor`) as single source of truth
- Wrapper CLI (`agent-sentinel run`) for safe tmux-aware agent launch
- Built-in + custom rule engine (keyword / regex / case-insensitive / cooldown)
- Aggregated top-right floating notification card (native style)
- Pane/session/window-aware jump to iTerm2 + tmux
- Local JSON/JSONL persistence only (no cloud, no telemetry)

## Repository Layout

```text
App/        # Menu bar UI, notification overlay, settings, jump integration
CLI/        # Wrapper commands: run/list/jump
Monitor/    # Local daemon: IPC server, event/state aggregation, persistence
Shared/     # Models, IPC protocol, rules, tmux/system abstractions
Resources/  # App metadata resources
Docs/       # Architecture and development docs
Tests/      # Shared + CLI tests
```

## Requirements

- macOS 14+
- Swift 5.10+ (`xcode-select --install` or Xcode toolchain)
- iTerm2
- tmux

## Build

```bash
swift build
```

Or via make:

```bash
make build
```

One-command install (recommended):

```bash
sudo make install
```

`make install` is root-safe: when invoked with `sudo`, it builds as the original user to avoid root-owned `.build` artifacts.

## Run (Development)

1. Start the monitor daemon:

```bash
.build-agent-sentinel/debug/sentinel-monitor
```

2. Start the menu bar app in another terminal:

```bash
.build-agent-sentinel/debug/SentinelApp
```

3. In an iTerm2 + tmux pane, run an agent through wrapper:

```bash
.build-agent-sentinel/debug/agent-sentinel run --agent claude --label auth-fix -- claude
```

Example for Codex:

```bash
.build-agent-sentinel/debug/agent-sentinel run --agent codex --label tests -- codex
```

## Daily Use (After Install)

```bash
make up
```

Then run agents in tmux:

```bash
agent-sentinel run --agent claude --label auth-fix -- claude
agent-sentinel run --agent codex --label tests -- codex
```

Useful commands:

```bash
make status
make logs
make down
```

`make up` now waits for monitor readiness (socket) before starting the app, so first start may take a few seconds.

## CLI Commands

```bash
agent-sentinel run --agent <claude|codex|gemini|custom> --label <label> -- <command...>
agent-sentinel list
agent-sentinel jump <pane-id-or-label>
```

## Data & Privacy

All runtime data stays local under:

```text
~/.agent-sentinel/
```

Files:

- `config.json` — app/monitor config
- `agents.json` — active/recent agent instances
- `events.jsonl` — structured event history
- `monitor.sock` — local Unix domain socket (0600)

Defaults:

- No cloud usage
- No telemetry
- No full terminal transcript persistence
- Only structured summaries are stored unless debug mode is enabled

## Testing

```bash
swift test
```

Current tests cover:

- IPC framing (including subscribe/snapshot)
- Rule engine matching + cooldown
- ANSI stripping
- Output processor line buffering and dedupe
- Jump service command path and failure handling

## Troubleshooting

- `Could not connect to sentinel-monitor`:
  - Start daemon manually: `.build/debug/sentinel-monitor`
  - Check socket: `ls -l ~/.agent-sentinel/monitor.sock`
- Jump failed / pane not found:
  - Pane may have exited; verify with `tmux list-panes -a`
- No notifications:
  - Ensure menu bar notifications toggle is enabled
  - Check rules in Settings > Rules
  - Validate monitor/app are connected (status dot in menu header)

## Notes

- Wrapper mode is first-class and stable.
- Non-wrapper attach monitoring is intentionally deferred for a later iteration.
- Storage is JSON-first for MVP simplicity; architecture is prepared for future SQLite migration.
