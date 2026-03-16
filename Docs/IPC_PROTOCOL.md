# IPC Protocol Specification

Version: 1.0 — derived from source code at `Shared/IPC/`

---

## Overview

Agent Sentinel uses a local Unix domain socket for all inter-process communication.
Three process types participate:

| Process | Role | Sends | Receives |
|---|---|---|---|
| **CLI Wrapper** (`agent-sentinel run`) | Per-agent PTY monitor | register, event, heartbeat, activity, resume, deregister | (none — fire-and-forget) |
| **Monitor Daemon** (`sentinel-monitor`) | State authority | snapshot, event (broadcast), configUpdate (broadcast) | All message types |
| **Menu Bar App** (`SentinelApp`) | UI subscriber | subscribe, ack, configUpdate, maintenance, sendKeys | snapshot, event, register, deregister, heartbeat, activity, resume, configUpdate |

**Socket path:** `~/.agent-sentinel/monitor.sock`
**Permissions:** `0600` (owner only)

---

## Wire Format

```
┌──────────────────┬───────────────────────────────────┐
│  4 bytes         │  N bytes                          │
│  UInt32 BE       │  UTF-8 JSON                       │
│  (payload len)   │  (IPCMessage)                     │
└──────────────────┴───────────────────────────────────┘
```

- **Length prefix:** 4-byte unsigned integer, big-endian, value = byte count of JSON body
- **JSON body:** UTF-8 encoded `IPCMessage` (ISO 8601 dates)
- **Max frame:** 4 MB (`4 * 1024 * 1024` bytes)
- **Multiple frames** may arrive in a single TCP read; the receiver must buffer and parse
  incrementally using the length prefix

### Encoding (IPCFraming.encode)

```swift
let json = JSONEncoder().encode(message)  // dateEncodingStrategy: .iso8601
var frame = UInt32(json.count).bigEndian  // 4-byte prefix
frame.append(json)                        // followed by JSON
```

### Decoding (IPCFraming.decode)

```swift
// Returns (message, bytesConsumed) or nil if buffer incomplete
func decode(from buffer: Data) throws -> (IPCMessage, Int)?
```

If `buffer.count < 4`, returns `nil`. If length > 4MB, throws `IPCError.decodingFailed`.

---

## Message Envelope

Every message is a JSON object with two fields:

```json
{
  "type": "<MessageType>",
  "payload": { ... }
}
```

`type` is one of: `register`, `event`, `deregister`, `heartbeat`, `activity`, `resume`,
`subscribe`, `snapshot`, `ack`, `configUpdate`, `maintenance`.

---

## Message Types

### register

**Direction:** CLI → Monitor
**When:** CLI wrapper starts monitoring an agent in a tmux pane
**Payload:** `AgentInstance`

```json
{
  "type": "register",
  "payload": {
    "id": "UUID",
    "agentType": "claude|codex|gemini|custom",
    "sessionName": "main",
    "sessionId": "$1",
    "windowId": "@0",
    "paneId": "%5",
    "windowName": "dev",
    "paneTitle": "",
    "cwd": "/path/to/project",
    "taskLabel": "auth-refactor",
    "pid": 12345,
    "startedAt": "2026-03-15T10:00:00Z",
    "lastActiveAt": "2026-03-15T10:00:00Z",
    "status": "running"
  }
}
```

**Monitor behavior:** Adds agent to registry. If another agent already occupies the same
`paneId`, the old agent is marked `expired` (pane collapse). Broadcasts to all subscribers.

### event

**Direction:** CLI → Monitor, Monitor → App (broadcast)
**When:** Rule engine matches agent output
**Payload:** `AgentEvent`

```json
{
  "type": "event",
  "payload": {
    "id": "UUID",
    "agentId": "UUID",
    "agentType": "claude",
    "displayLabel": "auth-refactor",
    "eventType": "permissionRequested|inputRequested|taskCompleted|errorDetected|stalledOrWaiting",
    "summary": "Task completed: Fixed authentication bug",
    "matchedRule": "Claude: Prompt ready",
    "priority": "high|normal",
    "shouldNotify": true,
    "dedupeKey": "agentId|ruleId|stableFragment",
    "timestamp": "2026-03-15T10:05:00Z",
    "paneId": "%5",
    "windowId": "@0",
    "sessionName": "main",
    "acknowledged": false
  }
}
```

**Monitor behavior:** Deduplicates by canonical summary within a type-specific window:
- `stalledOrWaiting`: 60s
- `taskCompleted`: 1s
- All others: 6s (configurable via `eventDedupeWindowSeconds`)

Accepted events are persisted to `events.jsonl` and broadcast to subscribers.

### deregister

**Direction:** CLI → Monitor
**When:** Wrapped agent process exits
**Payload:** `{ "agentId": "UUID", "exitCode": 0 }`

**Monitor behavior:** If `exitCode == 0`, synthesizes a `taskCompleted` event. Removes agent
from active registry. Clears stall alerts for this agent. Broadcasts to subscribers.

### heartbeat

**Direction:** CLI → Monitor
**When:** Every 5 seconds from the CLI wrapper
**Payload:** `{ "agentId": "UUID" }`

**Monitor behavior:** Updates `lastActiveAt` on the agent instance. Does NOT reset stall
state or acknowledge waiting events.

### activity

**Direction:** CLI → Monitor
**When:** OutputProcessor detects meaningful output after a quiet period
**Payload:** `{ "agentId": "UUID" }`

**Monitor behavior:** Updates `lastActiveAt`. If agent was `stalled`, transitions to
`running`. Resets stall alert gate. Auto-acknowledges recent `stalledOrWaiting` events.
Broadcasts to subscribers.

### resume

**Direction:** CLI → Monitor
**When:** User types into the PTY (meaningful input detected)
**Payload:** `{ "agentId": "UUID" }`

**Monitor behavior:** Updates `lastActiveAt`. Transitions `waiting`/`stalled` → `running`.
Resets stall alert gate. Auto-acknowledges recent `waiting`/`stalled` events.
Broadcasts to subscribers.

### subscribe

**Direction:** App → Monitor
**When:** App connects (or reconnects) to monitor
**Payload:** `SubscribeRequest`

```json
{
  "type": "subscribe",
  "payload": {
    "clientId": "UUID",
    "kind": "app|wrapper"
  }
}
```

**Monitor behavior:** Adds client to subscriber list. Immediately sends a `snapshot` response
with current state.

### snapshot

**Direction:** Monitor → App
**When:** In response to `subscribe`
**Payload:** `MonitorSnapshot`

```json
{
  "type": "snapshot",
  "payload": {
    "agents": [ ...AgentInstance array... ],
    "events": [ ...AgentEvent array... ],
    "config": { ...AppConfig... }
  }
}
```

**App behavior:** Replaces local state with snapshot contents. Replays recent completion
events as notifications (within 30s window).

### configUpdate

**Direction:** App → Monitor, Monitor → App (broadcast)
**When:** User changes settings in the App
**Payload:** `AppConfig` (full config object)

**Monitor behavior:** Validates and normalizes config. Persists to `config.json`. Broadcasts
updated config to all subscribers (including CLI wrappers for hot rule reload).

### ack

**Direction:** App → Monitor (reserved)
**When:** User acknowledges an event in the UI
**Payload:** `{ "messageId": "UUID" }`

**Status:** Defined but not yet fully wired. Events are acknowledged locally in the App's
`AgentRegistry`.

### maintenance

**Direction:** App → Monitor
**When:** User triggers maintenance action (e.g., clear history)
**Payload:** `MaintenanceRequest`

### sendKeys

**Direction:** App → Monitor
**When:** User clicks Yes/No on a permission notification, or types a reply and hits Enter
**Payload:** `SendKeysRequest`

```json
{
  "type": "sendKeys",
  "payload": {
    "paneId": "%5",
    "text": "y",
    "enterAfter": true
  }
}
```

**Monitor behavior:** Calls `TmuxClient.sendKeys(to: paneId, text: text, enterAfter: enterAfter)`.
Uses `tmux send-keys -t paneId -l -- text` (literal, no injection risk) followed by
`tmux send-keys -t paneId Enter` if `enterAfter` is true. Logs warning on failure.
No broadcast — this is a point-to-point action.

---

## Agent Lifecycle

```
CLI starts
  │
  ├─ register ──────────────────── Monitor adds to registry
  │                                  └─ broadcast to App
  │
  ├─ heartbeat (every 5s) ──────── Monitor updates lastActiveAt
  │
  ├─ activity (on output) ──────── Monitor: stalled → running
  │
  ├─ resume (on user input) ────── Monitor: waiting → running
  │                                  └─ auto-ack stalled/waiting events
  │
  ├─ event (on rule match) ──────── Monitor deduplicates, persists
  │                                  └─ broadcast to App
  │                                       └─ App shows notification
  │
  └─ deregister (process exits) ── Monitor: synthesize completion if exit=0
                                     └─ remove from active agents
                                     └─ broadcast to App
```

## Stall Detection

Two independent mechanisms:

1. **CLI-side (OutputProcessor):** If no output for `stallTimeout` seconds (default 120),
   emits a `stalledOrWaiting` event via IPC.

2. **Monitor-side (MonitorState):** Every 10 seconds, checks all agents. If an agent's
   `lastActiveAt` exceeds `activeAgentTTLSeconds` (default 900), marks it `expired` and
   synthesizes an expiration event.

## Connection Recovery

- **App reconnects** every 1.5s on disconnect
- On reconnect, receives fresh `snapshot`
- Recent `taskCompleted` events (within 30s) are replayed as notifications
- `EventPolicy.normalizeHistory()` acknowledges stale waiting/stalled events on startup

---

## Data Persistence

| File | Format | Purpose |
|---|---|---|
| `~/.agent-sentinel/config.json` | JSON | User configuration |
| `~/.agent-sentinel/events.jsonl` | JSON Lines | Append-only event history |
| `~/.agent-sentinel/agents.json` | JSON | Active/recent agent registry |
| `~/.agent-sentinel/monitor.sock` | Unix socket | IPC endpoint |
| `~/.agent-sentinel/monitor.lock` | flock | Single-instance daemon lock |
