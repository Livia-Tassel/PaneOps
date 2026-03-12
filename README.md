# Agent Sentinel (MVP)

Agent Sentinel is a native macOS local-first tool for monitoring multiple AI agents running in tmux panes, with fast menu-bar visibility and one-click jump back to the exact pane in iTerm2.

## What Is Included

- Native menu bar app (`SentinelApp`) using SwiftUI + AppKit
- Local monitor daemon (`sentinel-monitor`) as single source of truth
- Wrapper CLI (`agent-sentinel run`) for safe tmux-aware agent launch
- Built-in + custom rule engine (keyword / regex / case-insensitive / cooldown)
- Aggregated top-right floating notification card (native style)
- Agent state tracking with recovery for input, stall, and reconnect paths
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

`make install` is root-safe: when invoked with `sudo`, it builds as the original user to avoid root-owned `.build` artifacts. It installs:

- `/Applications/Agent Sentinel.app`
- `/usr/local/bin/agent-sentinel`
- `/usr/local/bin/sentinel-monitor`
- `/usr/local/bin/sentinel-app` as a launcher for the installed app bundle

## Packaging for GitHub Releases

Release assets are generated from a single version source: [`VERSION`](VERSION).

Build a distributable folder + tarball:

```bash
make dist
```

Output:

- `dist/AgentSentinel-<version>-macOS/`
- `dist/AgentSentinel-<version>-macOS.tar.gz`

Build a macOS installer package:

```bash
make pkg
```

Output:

- `dist/AgentSentinel-<version>.pkg`

Optional signing:

```bash
APP_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
INSTALLER_SIGNING_IDENTITY="Developer ID Installer: Your Name (TEAMID)" \
make pkg
```

`make pkg` can sign the embedded app and binaries when `APP_SIGNING_IDENTITY` is set, and the installer package when `INSTALLER_SIGNING_IDENTITY` is set. Notarization is not automated in this repo.

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

After pulling updates, restart the local services:

```bash
make down
make up
```

If you use the installed binaries under `/usr/local/bin`, reinstall after updates:

```bash
sudo make install
```

## CLI Commands

```bash
agent-sentinel run --agent <claude|codex|gemini|custom> --label <label> -- <command...>
agent-sentinel list
agent-sentinel jump <pane-id-or-label>
```

## Agent State Lifecycle

Agent Sentinel tracks a small runtime state machine for each wrapped agent:

- `running` — normal active state
- `waiting` — agent requested input or permission
- `stalled` — no output seen for `stallTimeoutSeconds` (default `120`)
- `completed` — process exited successfully
- `errored` — process exited non-zero
- `expired` — monitor determined the pane/session/context is gone or stale

Recovery rules:

- A `waiting` agent returns to `running` when you type back into the wrapped session.
- A `stalled` or `expired` agent returns to `running` on later heartbeat/activity.
- `errorDetected` output creates an error event, but does not by itself mark the process as terminally failed.
- Old `waiting` / `stalled` events are acknowledged automatically when the agent recovers.

This keeps the menu bar list, badge count, and notification overlay aligned with the real runtime state instead of leaving agents stuck in `waiting` or `stalled`.

## Notification Behavior

Built-in rules currently recognize common interactive patterns for Claude, Codex, and Gemini.

Notable cases:

- standalone prompts such as `❯`
- Codex inline prompts such as `› hello`
- permission prompts such as `(y/n)` or `yes/no`
- explicit completion lines such as `completed` or `all done`

Notifications are shown for:

- input requested
- permission requested
- task completed
- stalled / waiting

Completed events are informational. Input, permission, and stall events remain actionable until acknowledged, expired, or automatically cleared by recovery.

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

- config normalization and versioned runtime metadata
- IPC client multi-frame receive and broken-pipe handling
- IPC framing (including subscribe/snapshot/resume)
- Rule engine matching + cooldown
- ANSI stripping
- Output processor line buffering, UTF-8 boundary handling, and dedupe
- monitor state recovery for stalled/waiting agents
- Jump service command path and failure handling

## Troubleshooting

- `Could not connect to sentinel-monitor`:
  - Start daemon manually: `.build-agent-sentinel/debug/sentinel-monitor`
  - Check socket: `ls -l ~/.agent-sentinel/monitor.sock`
- Jump failed / pane not found:
  - Pane may have exited; verify with `tmux list-panes -a`
- No notifications:
  - Ensure menu bar notifications toggle is enabled
  - Check rules in Settings > Rules
  - Validate monitor/app are connected (status dot in menu header)
  - If you just updated the repo, run `make down && make up`
  - If you use installed binaries, rerun `sudo make install`
- Codex turn completed but no popup:
  - Use the wrapper: `agent-sentinel run --agent codex -- codex`
  - Make sure you are running inside `tmux`
  - Current built-in rules handle both standalone Codex prompts and inline prompts such as `› hello`
- Agent appears stuck in `waiting` or `stalled`:
  - Type back into the wrapped session to resume `waiting`
  - Later output/heartbeat should clear `stalled`
  - If the UI still looks stale after an update, restart services with `make down && make up`

## Notes

- Wrapper mode is first-class and stable.
- Non-wrapper attach monitoring is intentionally deferred for a later iteration.
- Storage is JSON-first for MVP simplicity; architecture is prepared for future SQLite migration.
