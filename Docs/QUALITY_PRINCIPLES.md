# Quality Principles for Agent Sentinel

Derived from *Vibe Coding 真解* and applied to this project.

---

## Why This Document Exists

Agent Sentinel started as a vibe project — a spontaneous idea to monitor AI coding agents
across tmux panes. The initial speed was a strength: it proved the concept fast. But that same
speed created structural debts that now make bugs hard to isolate and changes risky.

This document captures the shift from "exploration zone" to "production zone" (Ch. 9 of the
article). The project meets all four switching thresholds:

1. **Code expected to live > 1 week** — it already has
2. **Entering main branch / reused by others** — it is the main branch
3. **Involves concurrency, state transitions, complex error paths** — IPC, actor state, PTY
4. **Affects core functionality** — the entire app is the product

The transition requires: interface documentation, tests, reviews, refactoring. No longer
optimizing for "generation speed."

---

## Core Principles

### 1. Responsibility Over Generation (Ch. 1)

> The problem is not "can it generate," but "can it take responsibility."

**For this project:** Every change must pass three gates before merging:
- **Define the rule:** What is the interface contract? What are the boundaries?
- **Review the output:** Does it maintain conceptual integrity?
- **Maintain the boundary:** Does it keep complexity contained?

**Concrete:** Before writing code for any subsystem, the interface spec in `Docs/` must exist
and be current. Code follows spec, not the other way around.

### 2. Efficiency ≠ Speed (Ch. 2)

> "Faster" does not automatically mean "better." Often it just means problems surface
> faster and structure fossilizes sooner.

**For this project:** We measure efficiency by:
- **Rework rate** — how often a fix introduces a new bug
- **Change locality** — can a fix stay within one file/module?
- **Test confidence** — do tests catch regressions before humans do?

**Anti-pattern to avoid:** "Fix it now, refactor later." In this project, "later" has already
arrived. Every `try?` (there are ~30) should be audited: is it genuinely acceptable to
silently swallow the error, or was it expedient?

### 3. Elegant Code = Survivable Code (Ch. 3)

> Elegance is a survival strategy: control maintenance cost, slow entropy growth, keep local
> changes local.

The article defines elegant code through:
- **Atomization** — single-responsibility units that can be understood, tested, replaced
- **Interface-first** — contracts before implementation
- **Mechanism vs. Strategy separation** — "how" and "under what conditions" live apart

**For this project:** The OutputProcessor (886 LOC) violates all three. It handles UTF-8
decoding, ANSI stripping, rate limiting, duplicate suppression, stall detection, Claude
completion detection, and Codex completion detection in a single class with ~40 private
fields. It works (37 tests pass), but any change risks side effects across unrelated concerns.

### 4. Complexity Budget (Ch. 5)

> A project can absorb only so much structural complexity at any stage. The budget is limited.

Four minimum standards before AI code enters the system:
1. **Readability** — can a maintainer understand intent, I/O, key paths quickly?
2. **Responsibility boundaries** — each function/module maps to one primary task
3. **Duplication control** — same rule not scattered across multiple places
4. **Architecture conformity** — new code has a clear home in the existing structure

**Budget signals (any one triggers immediate review):**
- A change spans > 3 files for a single requirement
- A new feature requires modifying code not obviously related
- A single change causes non-obvious test failures elsewhere

### 5. Prompt as Design Document (Ch. 6)

> When prompt becomes a reviewable, versioned design document, generation output gains
> structural stability.

For any non-trivial change to Agent Sentinel, the prompt/task description should follow the
six-section structure:
1. **Context** — system environment, task type, current stage
2. **Goal** — what "done" looks like, in verifiable terms
3. **Constraints** — explicit prohibitions and hard boundaries
4. **Interface & Data** — input/output formats, data structures, error semantics
5. **Process** — ordered steps, not "do everything at once"
6. **Review** — acceptance criteria and rejection conditions

### 6. Review as First-Class Activity (Ch. 7)

> Code Review covers four dimensions: correctness, readability, maintainability, evolvability.

For this project, every change is evaluated against:
- **Correctness:** Does it solve the stated problem? Are failure paths covered?
- **Readability:** Can the intent be understood without running the code?
- **Maintainability:** Does it introduce duplication or cross-cutting concerns?
- **Evolvability:** Does it leave room for tomorrow's change?

**Reject list (any match → rework before merge):**
- Cross-layer responsibility mixing (e.g., UI logic in IPC handler)
- Duplicated logic across files without shared abstraction
- Hidden side effects (mutation not visible from call site)
- Key paths without test coverage
- No test coverage for state transitions or boundary conditions

---

## Application to Current Architecture

| Component | Status | Primary Risk | Next Action |
|---|---|---|---|
| IPC Protocol (Shared/IPC/) | Solid | Low | Document spec (done: IPC_PROTOCOL.md) |
| Rule Engine (Shared/Rules/) | Solid | Low — knowledge-heavy patterns | Maintain test coverage |
| Models (Shared/Models/) | Solid | Low | Stable |
| Policies (Shared/Policies/) | Solid | Low | Stable, well-tested |
| OutputProcessor (CLI/) | Fragile | **High** — monolith, timer-based detection | Decompose (see REFACTORING_ROADMAP.md) |
| MonitorState (Monitor/) | Complex | **Medium** — intricate dedupe/collapse | Extract strategies (see REFACTORING_ROADMAP.md) |
| SettingsView (App/) | Dense | Low — UI only | Split into tab views (low priority) |
| Tmux/Jump (Shared/Tmux/) | Solid | Low | Stable |

---

## Working Agreement

1. **Spec before code.** For any module touched, its interface doc must be current first.
2. **Test at boundaries.** State transitions, IPC messages, and rule matching must have tests.
3. **One concern per change.** A PR addresses one thing. Refactoring and features never mix.
4. **Budget check.** Before merging, ask: does this increase or decrease system complexity?
5. **No silent failures.** Every `try?` must have a comment explaining why silence is safe.
