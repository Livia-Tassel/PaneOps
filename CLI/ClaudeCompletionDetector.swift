import Foundation
import SentinelShared

/// Claude-specific completion detection.
///
/// Claude signals completion by showing a prompt symbol (❯, ❱, ›, >) after its response.
/// This detector uses a deferred timer: when a prompt is seen, it waits a quiet period
/// before emitting, because Claude may continue outputting after a brief prompt flash.
///
/// Key behaviors:
/// - Status/thinking lines (✢ Thinking...) are filtered from summary candidates
/// - Chrome lines (ctrl+g, status bar) are filtered from summary candidates
/// - Prompt is deferred by 0.6s (if assistant output seen) or 0.9s+ (if only status seen)
/// - If new assistant output arrives during the timer, the timer is cancelled
/// - Fallback summary "Response completed" used when no real content was captured
///
/// Thread safety: All mutable turn state is protected by `lock` since it is accessed
/// from both the caller context (observeLine, resetTurn, etc.) and the detached timer task.
final class ClaudeCompletionDetector: CompletionDetector {

    // MARK: - Thread-safe state

    private let lock = NSLock()
    private var _hasEmittedCompletion = false
    private var _hasSeenAssistantOutput = false
    private var _latestSummary = ""
    private var _hasSeenPromptReady = false

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

    private var hasSeenPromptReady: Bool {
        get { lock.withLock { _hasSeenPromptReady } }
        set { lock.withLock { _hasSeenPromptReady = newValue } }
    }

    // MARK: - Non-shared state

    private var completionTimer: Task<Void, Never>?
    private let quietPeriod: TimeInterval
    private let fallbackMinimumDelay: TimeInterval

    private static let statusSymbols: Set<Character> = Set("✢✣✤✥✦✧✩✪✫✬✭✮✯✰✱✲✳✴✵✶✷✸✹✺✻✼✽✾✿❇")

    init(quietPeriod: TimeInterval = 0.6, fallbackMinimumDelay: TimeInterval = 0.9) {
        self.quietPeriod = quietPeriod
        self.fallbackMinimumDelay = fallbackMinimumDelay
    }

    func observeLine(_ line: String, matchedEventType: EventType?, isPromptLike: Bool) {
        guard !line.isEmpty else { return }
        guard !isPromptLike else { return }
        guard !isLikelySeparatorLine(line) else { return }
        guard !isLikelyStatusLine(line) else { return }
        guard !isLikelyChromeLine(line) else { return }

        switch matchedEventType {
        case .taskCompleted?, .inputRequested?, .permissionRequested?:
            return
        default:
            break
        }

        let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        guard !isLikelyLowSignalSummary(candidate) else { return }

        lock.withLock {
            _latestSummary = candidate
            _hasSeenAssistantOutput = true
            if _hasSeenPromptReady {
                _hasSeenPromptReady = false
            }
        }
        completionTimer?.cancel()
    }

    func shouldSuppressCompletion(summary: String, isPromptEcho: Bool) -> Bool {
        if hasEmittedCompletion { return true }
        if isPromptEcho { return true }
        return false
    }

    func handleDeferredCompletion(rule: Rule, onEmit: @escaping @Sendable (Rule, String) -> Void) -> Bool {
        guard !hasEmittedCompletion else { return true }

        hasSeenPromptReady = true
        let delay: TimeInterval = hasSeenAssistantOutput
            ? quietPeriod
            : max(quietPeriod * 3, fallbackMinimumDelay)

        completionTimer?.cancel()
        completionTimer = Task.detached { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            let summary: String? = self.lock.withLock {
                guard !self._hasEmittedCompletion else { return nil }
                self._hasEmittedCompletion = true
                self._hasSeenPromptReady = false
                return self.trustedSummaryLocked() ?? "Response completed"
            }
            if let summary {
                onEmit(rule, summary)
            }
        }
        return true
    }

    func resolvedSummary(isPromptLike: Bool) -> String? {
        guard isPromptLike else { return nil }
        return lock.withLock { trustedSummaryLocked() } ?? "Response completed"
    }

    func markCompletionEmitted() {
        lock.withLock {
            _hasEmittedCompletion = true
            _hasSeenPromptReady = false
        }
        completionTimer?.cancel()
    }

    func resetTurn() {
        lock.withLock {
            _hasEmittedCompletion = false
            _latestSummary = ""
            _hasSeenAssistantOutput = false
            _hasSeenPromptReady = false
        }
        completionTimer?.cancel()
    }

    func cancelTimers() {
        completionTimer?.cancel()
    }

    // MARK: - Claude-specific filters (pure functions, no lock needed)

    private func isLikelyStatusLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else { return false }
        guard let first = trimmed.first, Self.statusSymbols.contains(first) else { return false }

        let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        let lowered = body.lowercased()

        let statusKeywords = [
            "thinking", "working", "analyzing", "analysing", "processing",
            "stewing", "lollygagging", "pondering", "reflecting",
            "思考", "分析", "处理中", "推理", "规划",
        ]
        if statusKeywords.contains(where: { lowered.contains($0) }) {
            return true
        }

        if body.range(
            of: #"^[A-Za-z][A-Za-z0-9\s\-]*(?:…|\.{3})(?:\s*\([^)]*\))?\s*$"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if body.range(
            of: #"^[A-Za-z][A-Za-z0-9\s\-]{0,42}(?:\s*\([^)]*\))?\s*$"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        return false
    }

    private func isLikelyChromeLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.contains("ctrl+g toedit") || lowered.contains("ctrl+g to edit") {
            return true
        }
        if lowered.contains("press ctrl-c again to exit") {
            return true
        }
        if lowered.range(of: #"^\s*try\s+"#, options: .regularExpression) != nil {
            return true
        }
        let pipeCount = line.reduce(into: 0) { count, character in
            if character == "|" { count += 1 }
        }
        if pipeCount >= 3 && (lowered.contains("sonnet") || lowered.contains("ctx:") || lowered.contains("master")) {
            return true
        }
        return false
    }

    /// Must be called while `lock` is held.
    private func trustedSummaryLocked() -> String? {
        let candidate = _latestSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        guard !isLikelyStatusLine(candidate) else { return nil }
        guard !isLikelyLowSignalSummary(candidate) else { return nil }
        return candidate
    }

    private func isLikelyLowSignalSummary(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if isLikelySeparatorLine(trimmed) { return true }

        let withoutPrefix = trimmed.replacingOccurrences(
            of: #"(?i)^\s*response completed:\s*"#,
            with: "",
            options: .regularExpression
        )
        if isLikelySeparatorLine(withoutPrefix) { return true }

        let scalarSet = CharacterSet(charactersIn: "-_=~─━═·• ")
        let nonWhitespace = withoutPrefix.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !nonWhitespace.isEmpty else { return true }
        return nonWhitespace.allSatisfy { scalarSet.contains($0) }
    }

    private func isLikelySeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        let separators = CharacterSet(charactersIn: "-_=~─━═")
        return trimmed.unicodeScalars.allSatisfy { separators.contains($0) }
    }
}
