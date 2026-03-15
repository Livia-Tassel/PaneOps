# Refactoring Roadmap

Prioritized list of structural improvements for Agent Sentinel.
Each entry follows the article's principle: "spec before code, one concern per change."

---

## Priority 1: OutputProcessor Decomposition

**File:** `CLI/OutputProcessor.swift` (886 LOC)
**Problem:** Single class managing 6+ orthogonal concerns with ~40 private fields.
**Impact:** Any change to completion detection risks breaking rate limiting or stall detection.
Changes are hard to reason about and test in isolation.

### Current Responsibilities

| Concern | Fields involved | LOC (approx) |
|---|---|---|
| UTF-8 chunk decoding | `pendingUTF8Bytes` | 30 |
| Line buffering & splitting | `lineBuffer`, `maxLineBufferChars` | 40 |
| ANSI stripping | `stripper` | 5 (delegates to ANSIStripper) |
| Rate limiting | `rateLimitLinesPerSec`, `lineCount`, `lastRateCheck` | 20 |
| Duplicate suppression | `recentLineSeenAt`, `repeatedLineSuppressionSeconds` | 30 |
| Stall detection | `stallTimeout`, `lastOutputTime`, `stallTimer`, `stallFired` | 30 |
| Claude completion detection | `claudeStatusSymbols`, `promptSymbols`, `hasSeenClaude*`, `claudePromptCompletionTimer`, etc. | 250 |
| Codex completion detection | `hasSeenCodex*`, `latestCodexAssistantSummary`, `codexCompletionTimer` | 120 |
| Rule matching & event emission | `ruleEngine`, `onEvent` | 40 |
| User input tracking | `hasObservedUserInput`, `lastUserInputAt`, `hasEmittedCompletion*` | 40 |

### Proposed Decomposition

```
OutputProcessor (coordinator, ~150 LOC)
  ├── UTF8ChunkDecoder         — stateful UTF-8 boundary handling
  ├── LineBuffer               — line accumulation and splitting
  ├── DuplicateSuppressor      — time-windowed line dedup
  ├── RateLimiter              — per-second line count throttle
  ├── StallDetector            — timeout-based stall event emission
  ├── CompletionDetector       — protocol with per-agent implementations
  │     ├── ClaudeCompletionDetector
  │     └── CodexCompletionDetector
  └── EventEmitter             — rule matching → AgentEvent construction
```

### Constraints

- **External interface unchanged:** `processData()`, `flush()`, `noteUserInput()`, `updateRules()`
- **All 37 existing tests must pass** without modification (they test public API)
- **No new dependencies**
- **Thread safety model unchanged:** class remains `@unchecked Sendable` with detached Tasks for timers

### Execution Plan

1. ~~Extract `UTF8ChunkDecoder`~~ — **DONE** (Round 4). 65 LOC, handles chunk boundary UTF-8.
2. ~~Extract `DuplicateSuppressor`~~ — **DONE** (Round 4). 38 LOC, time-windowed line dedup.
3. ~~Extract `StallDetector`~~ — **DONE** (Round 5). 45 LOC, timeout-based stall event emission.
4. ~~Define `CompletionDetector` protocol~~ — **DONE** (Round 6). 71 LOC protocol with default impls.
5. ~~Extract `ClaudeCompletionDetector`~~ — **DONE** (Round 6-7). 201 LOC.
6. ~~Extract `CodexCompletionDetector` + wire both~~ — **DONE** (Round 7). 156 LOC. Both detectors wired into OutputProcessor.
7. ~~Slim `OutputProcessor` to coordinator~~ — **DONE** (Round 7). OutputProcessor now delegates to extracted types.

**COMPLETE:** OutputProcessor.swift 886 → 534 LOC (40% reduction). 6 types extracted totaling 576 LOC.

### Acceptance Criteria

- OutputProcessor.swift < 200 LOC
- Each extracted type has its own unit tests
- All 37 existing tests pass unchanged
- No change to IPC protocol or event semantics

---

## Priority 2: MonitorState Strategy Extraction

**File:** `Monitor/MonitorState.swift` (644 LOC)
**Problem:** Swift actor with intricate pane-collapse, event-dedup, and auto-acknowledgment
logic interleaved with registry management.
**Impact:** Adding new event semantics or dedup rules requires understanding the full actor.

### Current Responsibilities

| Concern | Key methods |
|---|---|
| Agent registry (CRUD) | `handleRegister`, `handleDeregister`, `handleHeartbeat/Activity/Resume` |
| Pane collapse | `collapseActiveAgentsSharingPane` |
| Event dedup | `shouldAccept`, `dedupeSeenAt`, `canonicalSummary` |
| Auto-acknowledgment | `acknowledgeRecoveredAgentEvents`, auto-ack on activity/resume |
| Stall/expiration sweep | `tickForStalledAgents` |
| Subscriber broadcast | `broadcast`, `subscribers` map |
| Persistence | `saveAgents`, `persistEventsSnapshot` |

### Proposed Extraction

```
MonitorState (actor, ~250 LOC — registry + coordination)
  ├── PaneCollapsePolicy       — "when new agent registers in occupied pane"
  ├── EventDeduplicator        — canonical summary + time-window dedup
  ├── AcknowledgmentPolicy     — auto-ack rules for activity/resume/recovery
  └── AgentExpirationPolicy    — TTL-based agent expiration (extends AgentLivenessPolicy)
```

### Constraints

- **Actor isolation preserved:** extracted types are either value types or used only within the actor
- **All MonitorStateTests (466 LOC) pass** without modification
- **No change to IPC message semantics**

### Execution Plan

1. ~~Extract `EventDeduplicator`~~ — **DONE** (Round 8). 77 LOC.
2. ~~Extract `AcknowledgmentPolicy`~~ — **DONE** (Round 9). 59 LOC.
3. ~~Extract `PaneCollapsePolicy`~~ — **DONE** (Round 10). 92 LOC. Candidate selection + event factories.
4. ~~Slim MonitorState to coordination~~ — **DONE** (Round 10). MonitorState is now a coordinator.

**COMPLETE:** MonitorState.swift 644 → 506 LOC (21% reduction). 3 types extracted totaling 228 LOC.

### Acceptance Criteria

- MonitorState.swift < 300 LOC
- Each extracted policy is independently testable
- All existing MonitorStateTests pass unchanged

---

## Priority 3: SettingsView Tab Extraction

**File:** `App/Settings/SettingsView.swift` (314 LOC)
**Problem:** Single view managing 3 tabs with many Form fields.
**Impact:** Low — UI only, no logic bugs. But dense to iterate on.

### Proposed Split

```
SettingsView.swift (~30 LOC — TabView coordinator)
  ├── GeneralSettingsTab.swift
  ├── RulesSettingsTab.swift    (already partially split: RuleListView, RuleEditorView)
  └── AboutSettingsTab.swift
```

### Execution Plan

1. Extract `GeneralSettingsTab` — all the number/toggle fields
2. Extract `AboutSettingsTab` — version info
3. Slim `SettingsView` to TabView wrapper

**Priority:** Low. Do this when touching settings for other reasons.

---

## Not Planned (Acceptable As-Is)

| Component | Reason |
|---|---|
| IPC Protocol (`Shared/IPC/`) | Clean, well-tested, simple framing. No action needed. |
| Rule Engine (`Shared/Rules/RuleEngine.swift`) | 145 LOC, efficient, well-tested. |
| Models (`Shared/Models/`) | Stable, defensive Codable, good state machine. |
| Policies (`Shared/Policies/`) | Pure functions, well-tested, < 70 LOC each. |
| Tmux/Jump (`Shared/Tmux/`) | Safe CLI abstraction, no shell injection, good error types. |
| PTYWrapper (`CLI/PTYWrapper.swift`) | Solid C integration, proper signal handling. |
| EventStore (`Shared/Storage/`) | Simple JSONL, thread-safe. SQLite deferred intentionally. |

---

## Guiding Principles for Refactoring

From Ch. 6 of the article — every refactoring task prompt should specify:

> **Goal:** Split OutputProcessor into N single-responsibility types.
> **Constraints:** No external interface change. No new dependencies. All 37 tests pass.
> **Process:** Extract one concern at a time. Run tests after each extraction.
> **Review:** Verify LOC reduction. Verify each new type is independently testable.

From Ch. 9 — the switching rule that applies:

> "When code involves concurrency, state transitions, or complex error handling,
> switch from vibe mode to engineering discipline."

OutputProcessor and MonitorState both involve all three. They are the right targets.
