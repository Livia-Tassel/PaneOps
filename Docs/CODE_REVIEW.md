# Code Review — Extracted Types (Round 11)

Four-dimension review per Vibe Coding 真解 Chapter 7: Correctness, Readability, Maintainability, Evolvability.

---

## CLI Layer

### UTF8ChunkDecoder (65 LOC) — CLEAN

- **Correctness**: Solid. The tail-scan approach (try dropping 1..3 bytes) correctly handles all UTF-8 boundary splits. The `combined.count <= 4` guard prevents infinite buffering of truly invalid bytes.
- **Edge case noted**: If a stream sends only invalid bytes in 5+ byte chunks, `String(decoding:as:)` lossy fallback activates — acceptable behavior, documented implicitly.
- **No issues found.**

### DuplicateSuppressor (38 LOC) — CLEAN, one minor note

- **Correctness**: Time-windowed dedup works correctly. Cache bounded at 512 entries with 5s eviction.
- **Minor**: `trimForBurst()` uses `Date()` internally — not injectable for testing. Low risk since it's a cache optimization, not correctness-critical.
- **No action needed.**

### StallDetector (45 → 55 LOC) — FIXED (Round 12)

- **Data race on `fired`**: Protected with `NSLock` via computed property. Timer callback and `reset()` now synchronize correctly.

### ClaudeCompletionDetector (201 → 222 LOC) — FIXED (Round 12)

- **Data race on turn state**: All four mutable fields (`hasEmittedCompletion`, `hasSeenAssistantOutput`, `latestSummary`, `hasSeenPromptReady`) protected with single `NSLock`. Timer callback acquires lock atomically for its check-and-mutate block. `trustedSummaryLocked()` variant reads `_latestSummary` directly under lock.

### CodexCompletionDetector (156 → 170 LOC) — FIXED (Round 12)

- **Data race on turn state**: Same lock pattern as Claude. All four mutable fields protected. `scheduleQuietCompletion()` captures current summary before scheduling and uses lock-guarded atomic check in timer callback.

---

## Monitor Layer

### EventDeduplicator (77 LOC) — CLEAN

- **Correctness**: Value type (`struct`), used only within the `MonitorState` actor — actor isolation protects all mutations. No thread safety concern.
- **Readability**: Clear separation of dedup map vs. stall alert gate.
- **No issues found.**

### AcknowledgmentPolicy (59 LOC) — CLEAN

- **Correctness**: Pure functions on `inout [AgentEvent]`. Linear scan is fine for expected event counts (<1000).
- **Readability**: Three methods map directly to three scenarios documented in the header.
- **No issues found.**

### PaneCollapsePolicy (92 LOC) — CLEAN

- **Correctness**: Candidate filter correctly excludes self, inactive agents, and empty paneIds. Sort by `startedAt` descending ensures newest-first processing.
- **Readability**: Factory methods are straightforward event construction.
- **No issues found.**

---

## Summary of Findings

| Type | Verdict | Issue |
|---|---|---|
| UTF8ChunkDecoder | CLEAN | — |
| DuplicateSuppressor | CLEAN | Minor: non-injectable Date in trimForBurst |
| StallDetector | FIXED | Data race on `fired` — now lock-protected |
| CompletionDetector | CLEAN | — |
| ClaudeCompletionDetector | FIXED | Data race on turn state — now lock-protected |
| CodexCompletionDetector | FIXED | Data race on turn state — now lock-protected |
| EventDeduplicator | CLEAN | — |
| AcknowledgmentPolicy | CLEAN | — |
| PaneCollapsePolicy | CLEAN | — |

All data races identified in Round 11 were fixed in Round 12 using `NSLock`-based synchronization. Build is warning-free, all 121 tests pass.
