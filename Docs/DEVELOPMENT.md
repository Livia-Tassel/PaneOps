# Development Guide

## Build Targets

- `SentinelShared`
- `SentinelCLI` (`agent-sentinel`)
- `SentinelMonitor` (`sentinel-monitor`)
- `SentinelApp` (`SentinelApp`)

## Useful Commands

```bash
make build
make test
make build-monitor
make build-app
```

## Local Run Loop

Terminal 1:

```bash
.build-agent-sentinel/debug/sentinel-monitor
```

Terminal 2:

```bash
.build-agent-sentinel/debug/SentinelApp
```

Terminal 3 (inside tmux pane):

```bash
.build-agent-sentinel/debug/agent-sentinel run --agent claude --label auth-refactor -- claude
```

## Config and State

Path: `~/.agent-sentinel`

- `config.json`: configurable behavior
- `events.jsonl`: append-only structured history
- `agents.json`: active/recent agents
- `monitor.sock`: IPC endpoint

## Debugging

- Enable debug output capture:
  - CLI: `--debug`
  - or settings: `debugMode=true`
- Logs use `os.Logger` categories:
  - `ui`, `monitor`, `tmux`, `rules`, `storage`, `ipc`

## Test Focus

- IPC framing and compatibility
- Rule matching and cooldown semantics
- Output parsing and buffering behavior
- Jump behavior and command ordering

## Known MVP Boundaries

- Wrapper-first monitoring is prioritized
- Existing pane attach mode is not fully implemented yet
- Storage is JSON/JSONL (SQLite deferred)
