import Foundation
import SentinelShared

/// Protocol for agent-specific completion detection strategies.
///
/// Each agent type (Claude, Codex, etc.) has different signals for when a response
/// is complete. The CompletionDetector encapsulates:
/// - Tracking which output lines are meaningful assistant content (vs. noise/chrome)
/// - Deciding whether a completion-type rule match should be suppressed
/// - Scheduling deferred completion (timer-based) for prompt-like signals
/// - Resolving the best summary text for completion events
///
/// The OutputProcessor owns one CompletionDetector per session and delegates
/// all completion-related decisions to it.
protocol CompletionDetector: AnyObject {
    /// Whether a completion event has been emitted in the current user turn.
    var hasEmittedCompletion: Bool { get }

    /// Whether meaningful assistant output has been observed since last user input.
    var hasSeenAssistantOutput: Bool { get }

    /// The latest captured completion summary text, or empty if none.
    var latestSummary: String { get }

    /// Observe a line of agent output. Track assistant activity and update summary.
    /// Called for every non-empty stripped line (or embedded prompt prefix).
    /// - Parameters:
    ///   - line: The ANSI-stripped, normalized line
    ///   - matchedEventType: The event type of any rule match on this line (nil if no match)
    ///   - isPromptLike: Whether this line matches prompt patterns
    func observeLine(_ line: String, matchedEventType: EventType?, isPromptLike: Bool)

    /// Should a taskCompleted match be suppressed based on turn state?
    /// Checks: already emitted this turn, prompt echo before assistant output.
    /// - Parameters:
    ///   - summary: The matched line text
    ///   - isPromptEcho: Whether this looks like a prompt echo within 0.35s of user input
    func shouldSuppressCompletion(summary: String, isPromptEcho: Bool) -> Bool

    /// Handle a prompt-like completion match. For agents that use deferred completion
    /// (Claude, Codex), this schedules a timer instead of emitting immediately.
    /// Returns true if the completion was handled (deferred), false to let caller emit now.
    func handleDeferredCompletion(rule: Rule, onEmit: @escaping @Sendable (Rule, String) -> Void) -> Bool

    /// Resolve the best summary for a completion event whose matched text is a prompt symbol.
    /// Returns the last meaningful assistant output line, or a fallback.
    func resolvedSummary(isPromptLike: Bool) -> String?

    /// Mark that a completion event was just emitted (sets hasEmittedCompletion = true).
    func markCompletionEmitted()

    /// Reset all turn state. Called when user input is detected.
    func resetTurn()

    /// Cancel any pending timers. Called from flush() when PTY closes.
    func cancelTimers()

    /// Normalize a line for summary candidacy (agent-specific preprocessing).
    func normalizeLine(_ line: String) -> String

    /// Extract a summary candidate from a normalized line (agent-specific).
    func summarizeCandidate(_ line: String) -> String
}

/// Default implementations for agents without special completion detection.
extension CompletionDetector {
    func normalizeLine(_ line: String) -> String { line }
    func summarizeCandidate(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
