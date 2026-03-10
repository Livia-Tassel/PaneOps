# Agent Sentinel Architecture

## High-Level Flow

```text
agent-sentinel run
  -> PTY capture + output processing
  -> IPC(event/register/heartbeat) over ~/.agent-sentinel/monitor.sock
  -> sentinel-monitor daemon
      -> in-memory registry + dedupe + persistence
      -> fanout to subscribed app clients
  -> SentinelApp menu bar + overlay notifications
      -> jump via tmux + iTerm2 activation
```

## Components

## Shared

- Domain models: `AgentInstance`, `AgentEvent`, `Rule`, `AppConfig`
- IPC protocol and framing
- Rule engine and ANSI stripping
- tmux/jump abstractions (`TmuxClient`, `JumpService`)
- command execution abstraction (`CommandRunner`)

## CLI

- Wrapper entrypoint (`run`) for agent launch in pane context
- PTY wrapper for interactive passthrough
- Output processing with rate limit + duplicate suppression
- Agent lifecycle reporting (register/heartbeat/event/deregister)

## Monitor

- Unix socket server
- State authority for agents/events/config
- Event dedupe and throttle
- Stalled detection via heartbeat timeout
- Snapshot + incremental broadcast to subscribers

## App

- MenuBarExtra UI with active agents and recent events
- Settings and rules editing (local config + monitor update)
- Aggregated floating notification panel
- Pane jump integration and user-friendly failure alerting

## IPC Message Contracts

- `register(AgentInstance)`
- `event(AgentEvent)`
- `heartbeat(agentId)`
- `deregister(agentId, exitCode)`
- `subscribe(SubscribeRequest)`
- `snapshot(MonitorSnapshot)`
- `configUpdate(AppConfig)`
- `ack(messageId)` (reserved)

## Safety Principles

- No network calls in runtime path
- No shell interpolation for external commands
- Local-only Unix socket with strict permissions
- Structured event persistence by default
- Optional debug output capture controlled by explicit flag/config
