# OutputProcessor Specification

Version: 1.0 — derived from `CLI/OutputProcessor.swift` (886 LOC) and 37 tests.
This document is the prerequisite for the Priority 1 decomposition in REFACTORING_ROADMAP.md.

---

## Purpose

OutputProcessor sits between the PTY (raw agent output) and the IPC layer (structured events).
It transforms a stream of arbitrary bytes into a filtered sequence of `AgentEvent` values,
solving several problems simultaneously:

1. **Byte → Line conversion** with UTF-8 boundary handling
2. **Noise reduction** via ANSI stripping, rate limiting, duplicate suppression
3. **Pattern matching** via the rule engine
4. **False positive suppression** via a cascade of heuristic guards
5. **Completion detection** with agent-specific timing strategies (Claude, Codex)
6. **Stall detection** via inactivity timeout

---

## Public Interface

```swift
public final class OutputProcessor: @unchecked Sendable {

    /// Create a processor bound to a specific agent instance.
    public init(
        agentId: UUID,
        agentType: AgentType,           // .claude, .codex, .gemini, .custom
        displayLabel: String,
        paneId: String = "",
        windowId: String = "",
        sessionName: String = "",
        rules: [Rule],                  // Active rule set from RuleEngine.effectiveRules()
        stallTimeout: TimeInterval = 120,
        rateLimitLinesPerSec: Int = 100,
        debugMode: Bool = false,
        suppressInteractiveUntilFirstInput: Bool = false,
        promptCompletionQuietPeriod: TimeInterval = 0.6,
        codexCompletionQuietPeriod: TimeInterval = 3,
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    )

    /// Feed raw PTY output. May be called with any chunk size.
    /// Invariant: all bytes eventually produce lines; no data is silently dropped.
    public func processData(_ data: Data)

    /// Flush remaining buffered content. Call when PTY closes.
    /// Cancels all pending timers. After flush(), no more events will be emitted.
    public func flush()

    /// Hot-swap the rule set (e.g., after config change via IPC).
    public func updateRules(_ rules: [Rule])

    /// Notify the processor that the user typed into the PTY.
    /// Returns true if the input was meaningful (not a terminal focus report).
    /// Resets turn state: completion flags, timers, summary tracking.
    @discardableResult
    public func noteUserInput(_ data: Data) -> Bool
}
```

### Thread Safety

- Class is `@unchecked Sendable`
- `processData()` and `noteUserInput()` are called from separate concurrent Tasks in RunCommand
- Timer callbacks run on detached Tasks (`Task.detached`)
- No internal locks — relies on serial call patterns from RunCommand's structured concurrency
- The `onEvent` callback is `@Sendable` and may be called from any thread (timer or main)

### Lifecycle

```
init() ──→ processData()* ──→ flush()
             ↑                    │
             │                    └─ cancels stallTimer, claudePromptCompletionTimer,
             │                       codexCompletionTimer
             │
      noteUserInput()* (interspersed with processData calls)
```

---

## Data Processing Pipeline

Each `processData(data)` call traverses this pipeline:

```
Raw Data (bytes)
    │
    ▼
┌─────────────────────┐
│ 1. UTF-8 Decode     │  Combine with pendingUTF8Bytes, split valid/pending
│    decodeUTF8Text()  │  If all valid → empty pending. If trailing incomplete → buffer 1-3 bytes.
└─────────────────────┘
    │ String
    ▼
┌─────────────────────┐
│ 2. Normalize         │  \r\n → \n, \r → \n
│    normalizeLineEndings()
└─────────────────────┘
    │ String
    ▼
┌─────────────────────┐
│ 3. Line Buffer       │  Append to lineBuffer (cap at 16,384 chars)
│    Split on \n       │  Complete lines go to processing; last partial stays in buffer
└─────────────────────┘
    │ [String] (complete lines)     │ String (partial, stays in buffer)
    ▼                               ▼
┌─────────────────────┐    ┌──────────────────────┐
│ 4. processLine()    │    │ 5. processBufferedCandidate()
│    (per complete     │    │    (for partial lines that may be
│     line)            │    │     a prompt without trailing \n)
└─────────────────────┘    └──────────────────────┘
```

### Step 4: processLine() Detail

```
Raw line
    │
    ▼
ANSI strip → normalizedLineForMatching()
    │
    ├─ Empty? → discard
    ├─ isLikelyLocalInputEcho? → discard (prompt echo within 0.35s of user input)
    │
    ▼
Embedded prompt split: "● Hello! ❯" → prefix="● Hello!", prompt="❯"
    │
    ├─ If embedded: observe prefix as completion summary
    │
    ▼
Rule engine match (on prompt portion if embedded, else full line)
    │
    ├─ No match → observe for Codex completion activity + completion summary
    │
    ▼ (match found)
Suppression cascade (ALL must pass):
    │
    ├─ 1. shouldSuppressInteractiveEventBeforeInput?
    │     Gate: suppress input/permission/completion events before first user input
    │     (only when suppressInteractiveUntilFirstInput=true)
    │
    ├─ 2. shouldSuppressCompletionForTurnState?
    │     Gate: suppress taskCompleted if already emitted one this turn,
    │     or if this looks like prompt echo before assistant output
    │
    ├─ 3. shouldSuppressLikelyMetaOrControlLine?
    │     Gate: suppress if line contains terminal control residue
    │     or looks like a rule description (meta-content about rules)
    │
    ├─ 4. shouldHandleDeferredPromptCompletion?
    │     Gate: for Claude/Codex, prompt-like completions are deferred
    │     (scheduled on timer instead of immediate emission)
    │
    ├─ 5. shouldSuppressRepeatedLine?
    │     Gate: same line (by first 120 chars) within 1.2s → suppress
    │
    ▼ (all passed)
emitMatchedEvent() → onEvent(AgentEvent)
```

### Step 5: processBufferedCandidate() Detail

Processes the current `lineBuffer` contents (partial line without trailing `\n`).
Only emits for interactive event types: `.inputRequested`, `.permissionRequested`, `.taskCompleted`.
This handles prompts like `❯` that appear without a trailing newline.

For lines > 120 chars, only matches if a prompt symbol appears at the tail after a separator.

---

## Completion Detection State Machine

### Turn Model

The processor tracks a "turn" — the cycle from user input to agent completion:

```
noteUserInput()
    │
    ├─ Reset: hasEmittedCompletionSinceLastUserInput = false
    ├─ Reset: latestCompletionSummary = ""
    ├─ Reset: hasSeenClaude/CodexAssistantOutput = false
    ├─ Cancel: all completion timers
    │
    ▼
Agent produces output lines
    │
    ├─ Non-prompt lines → tracked as "assistant output"
    │   (updates latestCompletionSummary, sets hasSeenAssistantOutput)
    │
    ▼
Agent shows prompt (❯, ❱, ›, >)
    │
    ├─ Claude: schedule deferred completion (timer)
    │   Delay = 0.6s if assistant output seen, else max(1.8s, 0.9s)
    │
    ├─ Codex: suppress prompt; rely on quiet completion instead
    │
    ▼
Timer fires (if not cancelled by new output)
    │
    ├─ Emit taskCompleted with resolved summary
    ├─ Set hasEmittedCompletionSinceLastUserInput = true
    │
    ▼
Subsequent prompts in same turn → suppressed
```

### Claude Completion Detection

**Signals observed:**

| Signal | Meaning | Action |
|---|---|---|
| `✢✣✤...✰` + text | Status/thinking line | Filter from summary candidates |
| Non-status text line | Assistant output | Track as `latestCompletionSummary` |
| `❯`, `❱`, `›`, `>` (alone or with suggestion) | Prompt ready | Schedule timer |
| Chrome line (ctrl+g, pipe-separated status bar) | UI decoration | Filter from summary candidates |
| Separator line (`───`, `===`, etc.) | Visual separator | Filter from summary candidates |

**Timer behavior:**
- If assistant output has been seen: wait `promptCompletionQuietPeriod` (0.6s default)
- If NO assistant output seen (only status lines): wait `max(quietPeriod * 3, 0.9s)`
- If new assistant output arrives during timer: cancel timer (prompt was mid-stream)
- If timer fires: emit `taskCompleted` with last non-status, non-separator summary line
- If no valid summary: emit "Response completed" (fallback)

### Codex Completion Detection

**Signals observed:**

| Signal | Meaning | Action |
|---|---|---|
| `• text` (bullet lead) | Assistant output start | Set hasSeenCodexAssistantOutput, capture summary |
| Non-bullet continuation | Continued output | Update summary, reschedule timer |
| `›` (prompt) | Input ready | Suppress (don't emit from prompt) |
| Chrome (model info, usage) | UI decoration | Ignore |

**Timer behavior:**
- Wait `codexCompletionQuietPeriod` (3s default) after last observed assistant output
- If timer fires: emit `taskCompleted` with "Response completed: {summary}"
- Rule name: "Codex: Quiet completion"

---

## Suppression Rules Reference

| Rule | Condition | Why |
|---|---|---|
| **Startup gate** | `suppressInteractiveUntilFirstInput && !hasObservedUserInput` | Prevent false positives from agent startup banners showing prompts |
| **One completion per turn** | `hasEmittedCompletionSinceLastUserInput` | Avoid duplicate completion notifications |
| **Prompt echo** | Prompt-like line within 0.35s of `noteUserInput()` && no assistant output yet | Terminal echo of the user's own prompt |
| **Meta/description lines** | Contains keywords like "rule", "regex", "keyword", "built-in", etc. | Agent discussing its own rules triggers false matches |
| **Control sequence residue** | Contains `[?2004h`, `[?1004h`, `[>7u`, etc. | Terminal mode-setting escapes that survived ANSI stripping |
| **Repeated line** | Same first 120 chars within 1.2s | Duplicate suppression |
| **Deferred prompt** | Prompt-like line for Claude/Codex taskCompleted | Handled via timer instead of immediate emission |

---

## Line Normalization

Before matching, each line passes through `normalizedLineForMatching()`:

1. Strip Unicode variation selectors (`U+FE0E`, `U+FE0F`)
2. Strip zero-width characters (`U+200B`, `U+200C`, `U+200D`, `U+2060`)
3. Replace non-breaking spaces (`U+00A0`, `U+202F`) with regular space
4. Trim leading/trailing whitespace
5. Strip trailing cursor glyphs (`▎▍▌▋▊▉█`)

---

## Rate Limiting

- Tracks `lineCount` per 1-second window
- When `lineCount > rateLimitLinesPerSec` (default 100): tightens duplicate cache retention
- **Lines are never dropped.** Rate limiting only affects duplicate-cache cleanup aggressiveness
- Under burst: cache entries older than 2s are evicted (vs normal 5s)

---

## Context Lines Buffer

OutputProcessor maintains a 5-line ring buffer of recently processed stripped lines.
When emitting events for actionable types (`permissionRequested`, `inputRequested`,
`taskCompleted`), the buffer contents are attached as `AgentEvent.contextLines`.

- **Buffer size:** 5 lines (configurable via `maxContextLines`)
- **Content:** ANSI-stripped, normalized lines (same as what rule matching sees)
- **Attached to:** permission, input, and completion events only
- **Not attached to:** error and stall events (`contextLines` is `nil`)
- **Purpose:** Provides popup notification with recent output context so the user
  can decide whether to click Yes/No or what reply to type

---

## Stall Detection

- On init: starts `stallTimer` (detached Task, sleeps for `stallTimeout`)
- On any `processData()` or `noteUserInput()`: resets timer
- If timer fires without reset: emits `stalledOrWaiting` event
- `stallFired` flag prevents re-firing until `noteUserInput()` resets it
- DedupeKey: `"{agentId}|stall"` — only one active stall alert per agent

---

## Debug Mode

When `debugMode: true`:
- Opens `~/.agent-sentinel/debug-output.log`
- Logs every ANSI-stripped line with `[STRIPPED]` prefix
- Logs every rule match with `[MATCH] rule=... type=...`

---

## User Input Classification

`noteUserInput()` filters out non-meaningful input before resetting turn state:

**Ignored sequences (terminal reports):**
- `ESC [ I` — focus gained (3 bytes)
- `ESC [ O` — focus lost (3 bytes)
- `ESC [ Pn ; Pn R` — cursor position report (variable length)

Everything else (including bare `\n`) is considered meaningful input.

---

## Test Coverage Map

37 tests covering the following behaviors:

| Behavior | Test(s) | Lines |
|---|---|---|
| Permission detection | `testDetectsPermissionRequest` | 6-28 |
| Error detection | `testDetectsError` | 30-52 |
| ANSI stripping before match | `testStripsANSIBeforeMatching` | 54-77 |
| No false positive on noise | `testNoMatchForIrrelevantOutput` | 79-99 |
| Summary truncation (200 chars) | `testSummarySanitization` | 101-113 |
| Duplicate suppression (1.2s) | `testSuppressesHighFrequencyDuplicateLines` | 115-141 |
| Partial line buffering | `testPartialLineBuffering` | 143-164 |
| Split UTF-8 across chunks | `testPreservesSplitUTF8PromptAcrossChunksAfterAssistantOutput` | 166-193 |
| Prompt without trailing \n | `testDetectsPromptWithoutTrailingNewlineAfterAssistantOutput` | 195-219 |
| No double-fire on buffered+newline | `testDoesNotDuplicateBufferedPromptWhenNewlineArrives` | 221-244 |
| Rate limit preserves critical lines | `testRateLimitDoesNotDropCriticalLines` | 246-275 |
| Meta/rule description suppression | `testSuppressesMetaRuleDescriptionFalsePositive` | 277-295 |
| Startup gate (suppress before input) | `testSuppressesInteractiveEventsBeforeFirstInputWhenEnabled` | 297-323 |
| Enter-only unlocks gate | `testEnterOnlyInputUnlocksSuppressedInteractiveEvents` | 325-351 |
| Codex CR rewrite suppression | `testSuppressesCodexPromptAfterCarriageReturnRewriteWithoutAssistantOutput` | 353-372 |
| Codex inline prompt suppression | `testSuppressesCodexInlinePromptWithoutTrailingNewlineUntilAssistantOutput` | 374-392 |
| Terminal focus report ignored | `testIgnoresTerminalFocusReportBeforeCodexStartupPrompt` | 394-415 |
| Claude prompt echo suppression | `testSuppressesClaudePromptEchoImmediatelyAfterUserInput` | 417-443 |
| Claude summary from last line | `testClaudePromptCompletionUsesLastAssistantLineVerbatim` | 445-469 |
| Claude fast response still fires | `testClaudePromptCompletionStillFiresForFastResponses` | 471-496 |
| Claude chevron (›) prompt | `testClaudePromptCompletionSupportsChevronVariantPrompt` | 498-523 |
| Claude heavy chevron (❱) prompt | `testClaudePromptCompletionSupportsHeavyChevronVariantPrompt` | 525-550 |
| Claude cursor glyph in prompt | `testClaudePromptCompletionSupportsPromptWithCursorGlyph` | 552-577 |
| Claude NBSP inline suggestion | `testClaudePromptCompletionSupportsInlinePromptSuggestionWithNBSP` | 579-604 |
| Claude embedded prompt | `testClaudePromptCompletionSupportsEmbeddedPromptOnSingleRenderedLine` | 606-629 |
| Claude post-prompt chrome ignored | `testClaudePromptCompletionIsNotCancelledByPostPromptStatusLine` | 631-657 |
| Claude long buffered separator+prompt | `testClaudePromptCompletionDetectsPromptTailFromLongBufferedLine` | 659-685 |
| Claude thinking line not completion | `testClaudeThinkingStatusDoesNotTriggerCompletionBeforeRealAnswer` | 687-719 |
| Claude separator line not summary | `testClaudePromptCompletionIgnoresSeparatorLineSummary` | 721-746 |
| Claude quiet-after-prompt timing | `testClaudePromptCompletionWaitsForQuietAfterPrompt` | 748-778 |
| Claude fallback summary | `testClaudePromptCompletionFallsBackWhenSummaryUnavailable` | 780-806 |
| Claude status+token not summary | `testClaudeStatusLineWithTokenSuffixDoesNotReplaceAnswerSummary` | 808-835 |
| Codex quiet completion | `testCodexQuietCompletionAfterAssistantOutputSilence` | 837-867 |
| Codex chrome not completion | `testCodexChromeDoesNotTriggerQuietCompletionBeforeAssistantOutput` | 869-888 |
| Codex dedup after quiet completion | `testCodexQuietCompletionSuppressesLaterPromptDuplicate` | 890-918 |
| Stall detection + refire after input | `testStallDetectionOnlyRefiresAfterUserInput` | 920-945 |
| Claude idle prompt suppression | `testSuppressesRepeatedClaudePromptReadyWhileIdle` | 947-973 |

---

## Decomposition Contract

Any refactored implementation MUST:

1. **Pass all 37 tests** without modification (they test the public interface)
2. **Preserve the public API** exactly as specified above
3. **Preserve the suppression cascade order** — guards are evaluated in sequence; reordering changes semantics
4. **Preserve timer semantics** — Claude 0.6s/0.9s delays, Codex 3s delay, stall timeout
5. **Preserve the `@unchecked Sendable` model** — no new locks unless provably necessary
6. **Not introduce new dependencies**
