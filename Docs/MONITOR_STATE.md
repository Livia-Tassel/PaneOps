# MonitorState Specification

Version: 1.0 — derived from `Monitor/MonitorState.swift` (644 LOC) and 4 integration tests.
This document is the prerequisite for the Priority 2 decomposition in REFACTORING_ROADMAP.md.

---

## Purpose

MonitorState is the central state authority in the Agent Sentinel system. It is a Swift `actor`
that owns the canonical registry of agents, events, and configuration. All mutations flow
through this single point, and all connected subscribers receive consistent updates via
broadcast.

**Responsibilities:**
1. Agent registry management (register, heartbeat, activity, resume, deregister)
2. Event acceptance with deduplication
3. Pane collision resolution (collapse)
4. Auto-acknowledgment of stale/recovered events
5. Periodic agent expiration (stall/liveness sweep)
6. Subscriber management and broadcast
7. Persistence (agents.json, events.jsonl, config.json)
8. Startup recovery (normalize stale state from previous run)

---

## Public Interface

```swift
actor MonitorState {

    init(
        tmux: TmuxClient = TmuxClient(),
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        config: AppConfig? = nil,
        eventStore: EventStore? = nil,
        initialAgents: [UUID: AgentInstance]? = nil,
        initialEvents: [AgentEvent]? = nil,
        persistAgents: (([UUID: AgentInstance]) -> Void)? = nil
    )

    /// Handle an incoming IPC message from a client connection.
    func handle(_ message: IPCMessage, from connection: IPCServer.ClientConnection) async

    /// Clean up when a client disconnects.
    func clientDisconnected(_ connection: IPCServer.ClientConnection)

    /// Periodic tick: expire stale agents, clean up dedupe map.
    /// Called every 10 seconds from SentinelMonitor's background task.
    func tickForStalledAgents() async
}
```

### Concurrency Model

- Swift `actor` — all state access is serialized by the actor's executor
- No internal locks needed (actor isolation guarantees exclusivity)
- `handle()` and `tickForStalledAgents()` are `async` to allow `await broadcast()`
- `nowProvider` is injectable for deterministic testing

---

## Internal State

| Field | Type | Purpose |
|---|---|---|
| `config` | `AppConfig` | Normalized configuration (mutable via configUpdate) |
| `agents` | `[UUID: AgentInstance]` | Canonical agent registry |
| `events` | `[AgentEvent]` | In-memory event history (capped at `maxStoredEvents`) |
| `dedupeSeenAt` | `[String: Date]` | Tracks last-seen time per canonical dedupe key |
| `stallAlertedAgentIDs` | `Set<UUID>` | Agents that have an active stall alert (gate to prevent re-fire) |
| `paneSupersededAgentIDs` | `Set<UUID>` | Agents replaced by a newer registration on the same pane |
| `subscribers` | `[UUID: ClientConnection]` | Connected app/wrapper clients |

### External Dependencies

| Dependency | Role |
|---|---|
| `TmuxClient` | Check pane/session existence for liveness policy |
| `EventStore` | Persist events to `events.jsonl` |
| `persistAgentsHandler` | Write `agents.json` (injectable for testing) |

---

## Message Handling

### subscribe

1. Add connection to `subscribers` map
2. Build `MonitorSnapshot` with current state (agents sorted by startedAt desc, events normalized)
3. Send snapshot to the subscribing client
4. If send fails, remove from subscribers

### register(AgentInstance)

1. Set `lastActiveAt` to now, `status` to `.running`
2. **Pane collapse:** find all active agents sharing the same `paneId` → mark them `.expired`, generate pane-replacement events, auto-ack their pending events, add to `paneSupersededAgentIDs`
3. Insert new agent into registry
4. Clear stall/pane-superseded state for new agent
5. Persist agents + events
6. Broadcast: collapse events, ack messages, then `register(updatedAgent)`

### heartbeat(agentId)

1. Look up agent; skip if not found or pane-superseded
2. Call `recordHeartbeat(at: now)` — updates `lastActiveAt` only
3. **Does NOT change status** — a heartbeat alone cannot recover a stalled agent
4. Persist agents
5. Broadcast `heartbeat(agentId)`

### activity(agentId)

1. Look up agent; skip if not found or pane-superseded
2. Record previous status
3. Call `recordOutputActivity(at: now)` — updates `lastActiveAt`, transitions `stalled/expired → running`
4. If status changed:
   - Remove from `stallAlertedAgentIDs`
   - Auto-ack recent `stalledOrWaiting` events for this agent
   - Persist agents + events
5. Broadcast `activity(agentId)` + ack messages

### resume(agentId)

1. Look up agent; skip if not found, pane-superseded, or not in `waiting/stalled/expired`
2. Call `recordResume(at: now)` — updates `lastActiveAt`, transitions to `running`
3. Remove from `stallAlertedAgentIDs`
4. Auto-ack recent `stalledOrWaiting`, `inputRequested`, `permissionRequested` events
5. Persist agents + events
6. Broadcast `resume(agentId)` + ack messages

### event(AgentEvent)

1. Skip if agent is pane-superseded
2. **Deduplication check** (`shouldAccept`) — see Event Deduplication section
3. If `taskCompleted` or `!shouldNotify`: auto-set `acknowledged = true`
4. Update stall alert gate
5. Apply event to agent status via `AgentInstance.apply(event:)`
6. Append to events array
7. Persist event (append to JSONL)
8. Broadcast `event(accepted)`

### deregister(agentId, exitCode)

1. If `exitCode == 0` AND agent not pane-superseded AND no recent `taskCompleted` in last 30s:
   - Synthesize a completion event ("Task completed (process exited successfully)")
   - Pass through deduplication
   - If accepted, persist and broadcast
2. Set agent status: `exitCode == 0` → `.completed`, else → `.errored`
3. Update `lastActiveAt` to now
4. Remove from `stallAlertedAgentIDs` and `paneSupersededAgentIDs`
5. Auto-ack pending `stalledOrWaiting/inputRequested/permissionRequested` events
6. Persist agents + events
7. Broadcast ack messages + `deregister(agentId, exitCode)`

### configUpdate(AppConfig)

1. Normalize and save new config
2. Re-normalize event history with new actionable window
3. Trim events, persist everything
4. Broadcast `configUpdate(config)`

### maintenance(MaintenanceRequest)

Actions: `clearLogs`, `clearEventHistory`, `clearAgentCache`, `clearAll`
After completion, broadcasts a fresh snapshot.

### ack(messageId)

1. Find event by ID, set `acknowledged = true`
2. Persist events, broadcast `ack(messageId)`

### sendKeys(SendKeysRequest)

1. Call `tmux.sendKeys(to: request.paneId, text: request.text, enterAfter: request.enterAfter)`
2. Log warning on failure
3. No state mutation, no broadcast — point-to-point action

---

## Event Deduplication

### Canonical Dedupe Key

```
"{agentId}|{eventType}|{paneId or 'none'}|{canonicalSummary}"
```

Where `canonicalSummary` = `EventPolicy.canonicalSummary()`:
- Lowercase
- Trim whitespace
- Replace all digit sequences with `#`
- Truncate to 160 chars

### Dedup Windows (per event type)

| Event Type | Window | Rationale |
|---|---|---|
| `stalledOrWaiting` | `max(60, config.eventDedupeWindowSeconds)` | Stall alerts shouldn't re-fire rapidly |
| `taskCompleted` | 1s | Keep completions responsive for rapid Q&A |
| `permissionRequested` | `config.eventDedupeWindowSeconds` (default 6) | Standard dedup |
| `inputRequested` | `config.eventDedupeWindowSeconds` (default 6) | Standard dedup |
| `errorDetected` | `config.eventDedupeWindowSeconds` (default 6) | Standard dedup |

### Stall Alert Gate

Independent of dedup, the `stallAlertedAgentIDs` set provides an additional gate:
- When a `stall-detection` event is accepted → agent added to set
- When any other event arrives for that agent → agent removed from set
- A second `stall-detection` event for the same agent is **rejected** (suppressed)
- Only `activity` or `resume` resets the gate (not `heartbeat`)

### Dedupe Map Cleanup

`cleanupDedupeMap()` runs on every `tickForStalledAgents()` call (every 10s):
- Threshold = `max(dedupeWindowSeconds * 12, 300)` seconds
- Entries older than threshold are evicted

---

## Pane Collapse

When a new agent registers on a pane that already has an active agent:

1. Find all active agents with matching `paneId` (excluding the incoming agent)
2. Sort by `startedAt` descending
3. For each candidate:
   - Set status to `.expired`, update `lastActiveAt`
   - Remove from `stallAlertedAgentIDs`
   - Add to `paneSupersededAgentIDs`
   - Generate a `stalledOrWaiting` event with `matchedRule: "monitor-expire-paneReplaced"`
   - Auto-ack all pending waiting/stalled/input events for that agent
4. Future events from pane-superseded agents are silently dropped
5. Future `deregister` for pane-superseded agents does NOT emit synthetic completion

**Invariant:** At most one active agent per pane at any time.

---

## Auto-Acknowledgment Rules

Events are auto-acknowledged in several scenarios:

| Trigger | Events Acknowledged | Event Types |
|---|---|---|
| `activity` (status change) | Same agent | `stalledOrWaiting` |
| `resume` | Same agent | `stalledOrWaiting`, `inputRequested`, `permissionRequested` |
| `deregister` | Same agent | `stalledOrWaiting`, `inputRequested`, `permissionRequested` |
| Pane collapse | Superseded agent | `stalledOrWaiting`, `inputRequested`, `permissionRequested` |
| Event acceptance | `taskCompleted` or `!shouldNotify` events | Self (on acceptance) |
| Startup recovery | All non-actionable events | Via `EventPolicy.normalizeHistory()` |

**`taskCompleted` and `errorDetected` are NEVER auto-acked** by agent lifecycle changes.
They must be explicitly acknowledged via `ack(messageId)`.

---

## Agent Expiration (tickForStalledAgents)

Runs every 10 seconds. For each active agent, checks `AgentLivenessPolicy.expirationReason()`:

| Reason | Condition |
|---|---|
| `heartbeatTimeout` | `lastActiveAt` > `activeAgentTTLSeconds` (default 900s) ago |
| `sessionMissing` | `tmux.sessionExists(sessionName)` returns false |
| `paneMissing` | `tmux.paneExists(paneId)` returns false |
| `noContextTimeout` | No paneId + inactive > `activeAgentTTLSeconds` |

On expiration:
1. Set status to `.expired`, update `lastActiveAt`
2. Generate a `stalledOrWaiting` event with `matchedRule: "monitor-expire-{reason}"`
3. Auto-ack pending events for that agent
4. Persist agents + events
5. Broadcast ack + event messages

---

## Startup Recovery

On `init()`, the following recovery steps run:

1. Load config (from file or provided), normalize
2. Load events (from JSONL or provided), normalize via `EventPolicy.normalizeHistory()`
3. Load agents (from JSON or provided)
4. For each active agent: check pane/session existence + heartbeat TTL
   - If expired: mark `.expired`, generate expiration event
5. Re-normalize events with updated active agent set
6. Trim events to `maxStoredEvents`
7. If any changes occurred: persist agents + events

**Startup recovery uses `isStartupRecovery: true`** in liveness policy, which applies a
different grace period (`staleAgentGraceSeconds`) for agents without pane context.

---

## Persistence Model

| File | When Written | Method |
|---|---|---|
| `agents.json` | On any agent state change | `saveAgents()` → sorted by startedAt, pretty-printed JSON |
| `events.jsonl` | On event append | `eventStore.append()` → single JSONL line |
| `events.jsonl` | On rewrite (ack, normalize) | `eventStore.rewrite()` → atomic full rewrite |
| `config.json` | On configUpdate | `config.save()` |

EventStore auto-rotates when line count exceeds `maxLines` (default from `maxStoredEvents`).

---

## Broadcast Behavior

`broadcast(_ message)` sends to all subscribers:
- If send fails for a subscriber, it is removed from the subscriber map (dead connection cleanup)
- Messages are sent sequentially to all subscribers (no parallelism)
- Broadcast is fire-and-forget; failures are silently handled

---

## Test Coverage Map

4 integration tests covering core state transitions:

| Behavior | Test | Key Assertions |
|---|---|---|
| Stall gate: heartbeat doesn't reset, resume does | `testHeartbeatDoesNotRecoverStalledAgentUntilResume` | Heartbeat broadcasts but doesn't clear stall gate; second stall suppressed; resume acks + re-enables stall detection |
| Resume recovers waiting + acks input event | `testResumeRecoversWaitingAgentAndAcknowledgesInputEvent` | Resume broadcasts + acks the pending inputRequested event |
| Activity recovers stalled + acks stall event | `testActivityRecoversStalledAgentAndAcknowledgesOldStallEvent` | Activity broadcasts + acks; re-enables stall detection for next occurrence |
| Register collapses same-pane agent + blocks stale events | `testRegisterCollapsesOlderActiveAgentOnSamePane` | Old agent expired, pending input acked, replacement event generated, stale completion from old agent silently dropped, synthetic exit completion suppressed |

### Coverage Gaps (potential additions)

- `configUpdate` broadcast behavior
- `deregister` with exitCode != 0
- `shouldEmitSyntheticCompletion` logic
- `tickForStalledAgents` TTL expiration
- `maintenance` actions
- Multiple simultaneous subscribers
- Dedupe map cleanup timing

---

## Decomposition Contract

Per REFACTORING_ROADMAP.md, the proposed extractions are:

| Extracted Type | Responsibility | Input | Output |
|---|---|---|---|
| `EventDeduplicator` | `shouldAccept()`, dedupe key, dedupe map lifecycle | Event + config | accept/reject |
| `PaneCollapsePolicy` | `collapseActiveAgentsSharingPane()` | agents dict + incoming agent | agents to expire |
| `AcknowledgmentPolicy` | `acknowledgeEndedAgentEvents()`, `acknowledgeRecoveredAgentEvents()` | events + agent context | event IDs to ack |
| `AgentExpirationPolicy` | `expirationReason()`, `makeExpirationEvent()` | agent + tmux + config | expiration events |

Any refactored implementation MUST:

1. **Pass all 4 integration tests** without modification
2. **Preserve actor isolation** — extracted types are value types or used only within the actor
3. **Preserve broadcast ordering** — collapse events before register, acks before resume, etc.
4. **Preserve persistence timing** — agents/events saved at the same points in the flow
5. **Preserve startup recovery behavior** exactly
6. **Target: MonitorState.swift < 300 LOC** after extraction
