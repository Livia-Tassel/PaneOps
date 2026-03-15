import Foundation
import SentinelShared

/// Codex-specific completion detection.
///
/// Codex signals assistant output with bullet-prefixed lines (• text) and does not
/// show a clear completion prompt. This detector uses a quiet-period timer:
/// after assistant output stops arriving for `quietPeriod` seconds, it emits completion.
///
/// Key behaviors:
/// - Bullet lines (• text) mark start of assistant output
/// - Chrome lines (model info, usage stats) are filtered
/// - Prompt symbols (›) are suppressed — completions come from quiet timer only
/// - A 3-second quiet period after last assistant output triggers completion
/// - Rule name for quiet completions: "Codex: Quiet completion"
///
/// Thread safety: All mutable turn state is protected by `lock` since it is accessed
/// from both the caller context (observeLine, resetTurn, etc.) and the detached timer task.
final class CodexCompletionDetector: CompletionDetector {

    // MARK: - Thread-safe state

    private let lock = NSLock()
    private var _hasEmittedCompletion = false
    private var _hasSeenAssistantOutput = false
    private var _latestSummary = ""
    private var _latestAssistantSummary = ""

    private(set) var hasEmittedCompletion: Bool {
        get { lock.withLock { _hasEmittedCompletion } }
        set { lock.withLock { _hasEmittedCompletion = newValue } }
    }

    private(set) var hasSeenAssistantOutput: Bool {
        get { lock.withLock { _hasSeenAssistantOutput } }
        set { lock.withLock { _hasSeenAssistantOutput = newValue } }
    }

    private(set) var latestSummary: String {
        get { lock.withLock { _latestSummary } }
        set { lock.withLock { _latestSummary = newValue } }
    }

    private var latestAssistantSummary: String {
        get { lock.withLock { _latestAssistantSummary } }
        set { lock.withLock { _latestAssistantSummary = newValue } }
    }

    // MARK: - Non-shared state

    private var completionTimer: Task<Void, Never>?
    private let quietPeriod: TimeInterval
    private let isPromptLike: (String) -> Bool

    /// Callback for when quiet completion fires. Set by OutputProcessor during wiring.
    var onQuietCompletion: (@Sendable (String) -> Void)?

    init(quietPeriod: TimeInterval = 3, isPromptLike: @escaping (String) -> Bool) {
        self.quietPeriod = quietPeriod
        self.isPromptLike = isPromptLike
    }

    func observeLine(_ line: String, matchedEventType: EventType?, isPromptLike: Bool) {
        let normalizedLine = normalizeLine(line)

        // Handle matched event interactions
        switch matchedEventType {
        case .taskCompleted?:
            completionTimer?.cancel()
            return
        case .inputRequested?, .permissionRequested?:
            completionTimer?.cancel()
            lock.withLock {
                _hasSeenAssistantOutput = false
                _latestAssistantSummary = ""
            }
            return
        default:
            break
        }

        guard !hasEmittedCompletion else { return }
        guard !isChromeLine(normalizedLine) else { return }

        if isAssistantLead(normalizedLine) {
            let summary = summarizeCandidate(normalizedLine)
            lock.withLock {
                _hasSeenAssistantOutput = true
                _latestAssistantSummary = summary
                _latestSummary = summary
            }
            scheduleQuietCompletion()
            return
        }

        guard hasSeenAssistantOutput else { return }
        guard !isPromptLike else { return }

        let summary = summarizeCandidate(normalizedLine)
        if !summary.isEmpty {
            lock.withLock {
                _latestAssistantSummary = summary
                _latestSummary = summary
            }
        }
        scheduleQuietCompletion()
    }

    func shouldSuppressCompletion(summary: String, isPromptEcho: Bool) -> Bool {
        if hasEmittedCompletion { return true }
        if isPromptEcho { return true }
        return false
    }

    func handleDeferredCompletion(rule: Rule, onEmit: @escaping @Sendable (Rule, String) -> Void) -> Bool {
        // Codex completions always come from the quiet timer, never from prompt matches
        return true
    }

    func resolvedSummary(isPromptLike: Bool) -> String? {
        guard !latestSummary.isEmpty else { return nil }
        return latestSummary
    }

    func markCompletionEmitted() {
        hasEmittedCompletion = true
        completionTimer?.cancel()
    }

    func resetTurn() {
        lock.withLock {
            _hasEmittedCompletion = false
            _latestSummary = ""
            _hasSeenAssistantOutput = false
            _latestAssistantSummary = ""
        }
        completionTimer?.cancel()
    }

    func cancelTimers() {
        completionTimer?.cancel()
    }

    func normalizeLine(_ line: String) -> String {
        guard let assistantMarker = line.range(of: "• ") else { return line }
        let prefix = String(line[..<assistantMarker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, isPromptLike(prefix) else { return line }
        return String(line[assistantMarker.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func summarizeCandidate(_ line: String) -> String {
        line
            .replacingOccurrences(of: #"^\s*•\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    private func isAssistantLead(_ line: String) -> Bool {
        line.range(of: #"^\s*•\s+\S.*$"#, options: .regularExpression) != nil
    }

    private func isChromeLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.contains("openai codex") || lowered.hasPrefix("model:") || lowered.hasPrefix("directory:") {
            return true
        }
        if line.contains("·") && (lowered.contains("% left") || lowered.contains("% used")) {
            return true
        }
        return false
    }

    private func scheduleQuietCompletion() {
        guard hasSeenAssistantOutput else { return }
        guard !hasEmittedCompletion else { return }

        let currentSummary = latestAssistantSummary
        guard !currentSummary.isEmpty else { return }

        completionTimer?.cancel()
        completionTimer = Task.detached { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.quietPeriod * 1_000_000_000))
            guard !Task.isCancelled else { return }

            let shouldEmit: Bool = self.lock.withLock {
                guard !self._hasEmittedCompletion else { return false }
                guard self._hasSeenAssistantOutput else { return false }
                self._hasEmittedCompletion = true
                self._latestSummary = "Response completed: \(currentSummary)"
                return true
            }
            if shouldEmit {
                self.onQuietCompletion?(currentSummary)
            }
        }
    }
}
