import Foundation
import SentinelShared

/// Processes output from a PTY: strips ANSI, matches rules, emits events.
public final class OutputProcessor: @unchecked Sendable {
    private let agentId: UUID
    private let agentType: AgentType
    private let displayLabel: String
    private let paneId: String
    private let windowId: String
    private let sessionName: String
    private let ruleEngine: RuleEngine
    private let stripper = ANSIStripper()
    private let onEvent: @Sendable (AgentEvent) -> Void
    private let debugMode: Bool
    private let debugFile: FileHandle?
    private let suppressInteractiveUntilFirstInput: Bool
    private let promptCompletionQuietPeriod: TimeInterval
    private let codexCompletionQuietPeriod: TimeInterval
    private var pendingUTF8Bytes = Data()

    // Rate limiting
    private let rateLimitLinesPerSec: Int
    private var lineCount = 0
    private var lastRateCheck = Date()

    // Stall detection
    private let stallTimeout: TimeInterval
    private var lastOutputTime = Date()
    private var stallTimer: Task<Void, Never>?
    private var stallFired = false

    // Line buffer for partial lines
    private var lineBuffer = ""
    private let maxLineBufferChars = 16_384
    private var recentLineSeenAt: [String: Date] = [:]
    private let repeatedLineSuppressionSeconds: TimeInterval = 1.2
    private var hasObservedUserInput = false
    private var lastUserInputAt: Date?
    private var hasEmittedCompletionSinceLastUserInput = false
    private var latestCompletionSummary = ""
    private var hasSeenClaudeAssistantOutputSinceLastUserInput = false
    private var claudePromptCompletionTimer: Task<Void, Never>?
    private var hasSeenCodexAssistantOutputSinceLastUserInput = false
    private var latestCodexAssistantSummary = ""
    private var codexCompletionTimer: Task<Void, Never>?

    public init(
        agentId: UUID,
        agentType: AgentType,
        displayLabel: String,
        paneId: String = "",
        windowId: String = "",
        sessionName: String = "",
        rules: [Rule],
        stallTimeout: TimeInterval = 120,
        rateLimitLinesPerSec: Int = 100,
        debugMode: Bool = false,
        suppressInteractiveUntilFirstInput: Bool = false,
        promptCompletionQuietPeriod: TimeInterval = 0.6,
        codexCompletionQuietPeriod: TimeInterval = 3,
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) {
        self.agentId = agentId
        self.agentType = agentType
        self.displayLabel = displayLabel
        self.paneId = paneId
        self.windowId = windowId
        self.sessionName = sessionName
        self.ruleEngine = RuleEngine(rules: rules)
        self.stallTimeout = stallTimeout
        self.rateLimitLinesPerSec = rateLimitLinesPerSec
        self.debugMode = debugMode
        self.suppressInteractiveUntilFirstInput = suppressInteractiveUntilFirstInput
        self.promptCompletionQuietPeriod = promptCompletionQuietPeriod
        self.codexCompletionQuietPeriod = codexCompletionQuietPeriod
        self.onEvent = onEvent

        if debugMode {
            let path = AppConfig.baseDirectory.appendingPathComponent("debug-output.log").path
            FileManager.default.createFile(atPath: path, contents: nil)
            self.debugFile = FileHandle(forWritingAtPath: path)
            self.debugFile?.seekToEndOfFile()
        } else {
            self.debugFile = nil
        }

        resetStallTimer()
    }

    /// Process a chunk of raw PTY output.
    public func processData(_ data: Data) {
        guard !data.isEmpty else { return }

        let now = Date()
        lastOutputTime = now
        stallFired = false
        resetStallTimer()

        let (decodedText, pendingBytes) = decodeUTF8Text(from: data)
        pendingUTF8Bytes = pendingBytes
        let text = normalizeLineEndings(decodedText)
        guard !text.isEmpty else { return }
        lineBuffer += text
        if lineBuffer.count > maxLineBufferChars {
            lineBuffer = String(lineBuffer.suffix(maxLineBufferChars))
        }

        // Split on newlines, keep the last partial line in buffer
        var lines = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.removeLast() // May be empty string if text ended with \n

        // Rate limiting: if exceeding threshold, only process last line of burst
        lineCount += lines.count
        if now.timeIntervalSince(lastRateCheck) >= 1.0 {
            lineCount = lines.count
            lastRateCheck = now
        }

        // Keep correctness first: never drop lines from rule matching path.
        // Under bursts we only tighten duplicate-cache retention to control memory.
        if lineCount > rateLimitLinesPerSec, recentLineSeenAt.count > 256 {
            let threshold = now.addingTimeInterval(-2)
            recentLineSeenAt = recentLineSeenAt.filter { $0.value > threshold }
        }
        for line in lines {
            processLine(line)
        }

        processBufferedCandidate()
    }

    /// Flush any remaining buffered content (call when PTY closes).
    public func flush() {
        if !pendingUTF8Bytes.isEmpty {
            let fallback = String(decoding: pendingUTF8Bytes, as: UTF8.self)
            lineBuffer += fallback
            pendingUTF8Bytes.removeAll(keepingCapacity: false)
        }
        if !lineBuffer.isEmpty {
            processLine(lineBuffer)
            lineBuffer = ""
        }
        stallTimer?.cancel()
        claudePromptCompletionTimer?.cancel()
        codexCompletionTimer?.cancel()
    }

    /// Update rules (e.g., from config change).
    public func updateRules(_ rules: [Rule]) {
        ruleEngine.updateRules(rules)
    }

    /// Let the processor know the user has typed into the PTY.
    /// This suppresses startup banner false positives for interactive events.
    @discardableResult
    public func noteUserInput(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        guard containsMeaningfulUserInput(data) else { return false }

        lastUserInputAt = Date()
        lastOutputTime = Date()
        stallFired = false
        resetStallTimer()
        hasEmittedCompletionSinceLastUserInput = false
        latestCompletionSummary = ""
        hasSeenClaudeAssistantOutputSinceLastUserInput = false
        claudePromptCompletionTimer?.cancel()
        hasSeenCodexAssistantOutputSinceLastUserInput = false
        latestCodexAssistantSummary = ""
        codexCompletionTimer?.cancel()

        guard suppressInteractiveUntilFirstInput, !hasObservedUserInput else { return true }
        hasObservedUserInput = true
        return true
    }

    // MARK: - Private

    private func processLine(_ rawLine: String) {
        let stripped = stripper.strip(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return }

        if isLikelyLocalInputEcho(stripped) { return }

        // Debug: log all stripped lines to file
        if debugMode, let fh = debugFile {
            let logLine = "[STRIPPED] \(stripped)\n"
            fh.write(logLine.data(using: .utf8)!)
        }

        let match = ruleEngine.match(line: stripped, agentType: agentType, agentId: agentId)
        if let match {
            if shouldSuppressInteractiveEventBeforeInput(match.rule.eventType) { return }
            if shouldSuppressCompletionForTurnState(match, summary: stripped) { return }
            if shouldSuppressLikelyMetaOrControlLine(stripped, eventType: match.rule.eventType) { return }
            if shouldHandleDeferredPromptCompletion(match, summary: stripped) { return }
            guard !shouldSuppressRepeatedLine(stripped) else { return }
            emitMatchedEvent(match, summary: stripped)
        }

        observeCodexCompletionActivity(line: stripped, matchedEventType: match?.rule.eventType)
        observeCompletionSummary(line: stripped, matchedEventType: match?.rule.eventType)
    }

    private func resetStallTimer() {
        stallTimer?.cancel()
        stallTimer = Task.detached { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.stallTimeout * 1_000_000_000))
            guard !Task.isCancelled, !self.stallFired else { return }
            self.stallFired = true

            let event = AgentEvent(
                agentId: self.agentId,
                agentType: self.agentType,
                displayLabel: self.displayLabel,
                eventType: .stalledOrWaiting,
                summary: "No output for \(Int(self.stallTimeout))s — agent may be stalled or waiting",
                matchedRule: "stall-detection",
                priority: .normal,
                shouldNotify: true,
                dedupeKey: "\(self.agentId.uuidString)|stall",
                paneId: self.paneId,
                windowId: self.windowId,
                sessionName: self.sessionName
            )
            self.onEvent(event)
        }
    }

    private func shouldSuppressRepeatedLine(_ line: String) -> Bool {
        let now = Date()
        let key = stableKeyFragment(from: line)
        if let seen = recentLineSeenAt[key], now.timeIntervalSince(seen) < repeatedLineSuppressionSeconds {
            return true
        }
        recentLineSeenAt[key] = now
        if recentLineSeenAt.count > 512 {
            let threshold = now.addingTimeInterval(-5)
            recentLineSeenAt = recentLineSeenAt.filter { $0.value > threshold }
        }
        return false
    }

    private func stableKeyFragment(from line: String) -> String {
        let lowered = line.lowercased()
        return String(lowered.prefix(120))
    }

    private func consumeBufferedPromptIfNeeded(_ line: String) {
        if isPromptLikeLine(line) {
            lineBuffer = ""
        }
    }

    private func processBufferedCandidate() {
        let stripped = stripper.strip(lineBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return }
        if isLikelyLocalInputEcho(stripped) {
            lineBuffer = ""
            return
        }
        guard stripped.count <= 120 else { return }

        let match = ruleEngine.match(line: stripped, agentType: agentType, agentId: agentId)
        if let match,
           match.rule.eventType == .inputRequested
            || match.rule.eventType == .permissionRequested
            || match.rule.eventType == .taskCompleted
        {
            if shouldSuppressInteractiveEventBeforeInput(match.rule.eventType) {
                consumeBufferedPromptIfNeeded(stripped)
                return
            }
            if shouldSuppressCompletionForTurnState(match, summary: stripped) {
                consumeBufferedPromptIfNeeded(stripped)
                return
            }
            if shouldSuppressLikelyMetaOrControlLine(stripped, eventType: match.rule.eventType) { return }
            if shouldHandleDeferredPromptCompletion(match, summary: stripped) {
                consumeBufferedPromptIfNeeded(stripped)
                return
            }
            if shouldSuppressRepeatedLine(stripped) {
                consumeBufferedPromptIfNeeded(stripped)
                return
            }
            emitMatchedEvent(match, summary: stripped)
            consumeBufferedPromptIfNeeded(stripped)
        }

        observeCodexCompletionActivity(line: stripped, matchedEventType: match?.rule.eventType)
        observeCompletionSummary(line: stripped, matchedEventType: match?.rule.eventType)
    }

    private func decodeUTF8Text(from data: Data) -> (String, Data) {
        var combined = pendingUTF8Bytes
        combined.append(data)

        if let text = String(data: combined, encoding: .utf8) {
            return (text, Data())
        }

        let maxTailBytes = min(3, combined.count)
        for tailCount in 1...maxTailBytes {
            let prefix = combined.dropLast(tailCount)
            if let text = String(data: prefix, encoding: .utf8) {
                return (text, Data(combined.suffix(tailCount)))
            }
        }

        if combined.count <= 4 {
            return ("", combined)
        }

        return (String(decoding: combined, as: UTF8.self), Data())
    }

    private func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func emitMatchedEvent(_ match: RuleEngine.MatchResult, summary: String) {
        let eventSummary = resolvedEventSummary(for: match, originalSummary: summary)
        if match.rule.eventType == .taskCompleted {
            hasEmittedCompletionSinceLastUserInput = true
            claudePromptCompletionTimer?.cancel()
            codexCompletionTimer?.cancel()
        }

        if debugMode, let fh = debugFile {
            let logLine = "[MATCH] rule=\(match.rule.name) type=\(match.rule.eventType.rawValue)\n"
            fh.write(logLine.data(using: .utf8)!)
        }

        let event = AgentEvent(
            agentId: agentId,
            agentType: agentType,
            displayLabel: displayLabel,
            eventType: match.rule.eventType,
            summary: eventSummary,
            matchedRule: match.rule.name,
            priority: match.rule.priority,
            shouldNotify: match.rule.triggersNotification,
            dedupeKey: "\(agentId.uuidString)|\(match.rule.id.uuidString)|\(stableKeyFragment(from: eventSummary))",
            paneId: paneId,
            windowId: windowId,
            sessionName: sessionName
        )
        onEvent(event)
    }

    private func shouldSuppressInteractiveEventBeforeInput(_ eventType: EventType) -> Bool {
        guard suppressInteractiveUntilFirstInput else { return false }
        guard !hasObservedUserInput else { return false }
        switch eventType {
        case .inputRequested, .permissionRequested, .taskCompleted:
            return true
        default:
            return false
        }
    }

    private func shouldSuppressLikelyMetaOrControlLine(_ line: String, eventType: EventType) -> Bool {
        if isLikelyControlSequenceResidue(line) { return true }

        switch eventType {
        case .inputRequested, .permissionRequested, .taskCompleted:
            return isLikelyRuleDescriptionLine(line)
        default:
            return false
        }
    }

    private func isLikelyControlSequenceResidue(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.contains("[?2004h")
            || lowered.contains("[?1004h")
            || lowered.contains("[?2026h")
            || lowered.contains("[>7u")
            || lowered.contains("[?u")
        {
            return true
        }
        return false
    }

    private func isLikelyRuleDescriptionLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let metaMarkers = [
            "rule", "rules", "regex", "keyword", "pattern", "event type",
            "input requested", "permission requested", "task completed",
            "detect events", "built-in", "builtin", "example", "examples",
            "内置示例", "匹配规则", "关键词", "正则", "事件类型", "提示词",
        ]
        if metaMarkers.contains(where: { lowered.contains($0) }) {
            return true
        }
        if lowered.contains("allow|") || lowered.contains("|allow") || lowered.contains("proceed|") {
            return true
        }
        return false
    }

    private func shouldSuppressCompletionForTurnState(
        _ match: RuleEngine.MatchResult,
        summary: String
    ) -> Bool {
        guard match.rule.eventType == .taskCompleted else { return false }
        if hasEmittedCompletionSinceLastUserInput {
            return true
        }
        if isLikelyPromptEchoBeforeAssistantOutput(summary) {
            return true
        }
        return false
    }

    private func shouldHandleDeferredPromptCompletion(
        _ match: RuleEngine.MatchResult,
        summary: String
    ) -> Bool {
        guard match.rule.eventType == .taskCompleted else { return false }
        guard isPromptLikeLine(summary) else { return false }

        switch agentType {
        case .claude:
            scheduleClaudePromptCompletion(rule: match.rule)
            return true
        case .codex:
            return true
        default:
            return false
        }
    }

    private func isLikelyLocalInputEcho(_ line: String) -> Bool {
        isLikelyPromptEchoBeforeAssistantOutput(line)
    }

    private func isLikelyPromptEchoBeforeAssistantOutput(_ line: String) -> Bool {
        guard let lastUserInputAt else { return false }
        guard !hasSeenAssistantOutputSinceLastUserInput() else { return false }
        guard Date().timeIntervalSince(lastUserInputAt) <= 0.35 else { return false }
        return isPromptLikeLine(line)
    }

    private func hasSeenAssistantOutputSinceLastUserInput() -> Bool {
        switch agentType {
        case .claude:
            return hasSeenClaudeAssistantOutputSinceLastUserInput
        case .codex:
            return hasSeenCodexAssistantOutputSinceLastUserInput
        default:
            return !latestCompletionSummary.isEmpty
        }
    }

    private func isPromptLikeLine(_ line: String) -> Bool {
        line.range(of: #"^\s*[❯›>](?:\s+\S.*)?$"#, options: .regularExpression) != nil
    }

    private func observeCompletionSummary(line: String, matchedEventType: EventType?) {
        let normalizedLine = normalizedCompletionSummaryLine(from: line)
        guard !normalizedLine.isEmpty else { return }
        guard !isPromptLikeLine(normalizedLine) else { return }
        guard !isLikelySeparatorLine(normalizedLine) else { return }
        guard !isLikelyControlSequenceResidue(normalizedLine) else { return }

        switch matchedEventType {
        case .taskCompleted?, .inputRequested?, .permissionRequested?:
            return
        default:
            break
        }

        if agentType == .codex, isLikelyCodexChromeLine(normalizedLine) {
            return
        }

        let candidate = summaryCandidate(from: normalizedLine)
        guard !candidate.isEmpty else { return }
        latestCompletionSummary = candidate
        if agentType == .claude, lastUserInputAt != nil {
            hasSeenClaudeAssistantOutputSinceLastUserInput = true
            claudePromptCompletionTimer?.cancel()
        }
    }

    private func resolvedEventSummary(for match: RuleEngine.MatchResult, originalSummary: String) -> String {
        guard match.rule.eventType == .taskCompleted else { return originalSummary }
        guard isPromptLikeLine(originalSummary) else { return originalSummary }
        guard !latestCompletionSummary.isEmpty else { return originalSummary }
        return latestCompletionSummary
    }

    private func normalizedCompletionSummaryLine(from line: String) -> String {
        if agentType == .codex {
            return normalizeCodexAssistantLine(line)
        }
        return line
    }

    private func summaryCandidate(from line: String) -> String {
        if agentType == .codex {
            return summarizeCodexAssistantLine(line)
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isLikelySeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        let separators = CharacterSet(charactersIn: "-_=~─━═")
        return trimmed.unicodeScalars.allSatisfy { separators.contains($0) }
    }

    private func observeCodexCompletionActivity(line: String, matchedEventType: EventType?) {
        guard agentType == .codex else { return }
        guard lastUserInputAt != nil else { return }
        let normalizedLine = normalizeCodexAssistantLine(line)

        switch matchedEventType {
        case .taskCompleted?:
            codexCompletionTimer?.cancel()
            return
        case .inputRequested?, .permissionRequested?:
            codexCompletionTimer?.cancel()
            hasSeenCodexAssistantOutputSinceLastUserInput = false
            latestCodexAssistantSummary = ""
            return
        default:
            break
        }

        guard !hasEmittedCompletionSinceLastUserInput else { return }
        guard !isLikelyCodexChromeLine(normalizedLine) else { return }

        if isLikelyCodexAssistantLead(normalizedLine) {
            hasSeenCodexAssistantOutputSinceLastUserInput = true
            latestCodexAssistantSummary = summarizeCodexAssistantLine(normalizedLine)
            scheduleCodexQuietCompletion()
            return
        }

        guard hasSeenCodexAssistantOutputSinceLastUserInput else { return }
        guard !isPromptLikeLine(normalizedLine) else { return }

        let summary = summarizeCodexAssistantLine(normalizedLine)
        if !summary.isEmpty {
            latestCodexAssistantSummary = summary
        }
        scheduleCodexQuietCompletion()
    }

    private func scheduleClaudePromptCompletion(rule: Rule) {
        guard agentType == .claude else { return }
        guard lastUserInputAt != nil else { return }
        guard hasSeenClaudeAssistantOutputSinceLastUserInput else { return }
        guard !hasEmittedCompletionSinceLastUserInput else { return }

        claudePromptCompletionTimer?.cancel()
        claudePromptCompletionTimer = Task.detached { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.promptCompletionQuietPeriod * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard !self.hasEmittedCompletionSinceLastUserInput else { return }
            guard self.hasSeenClaudeAssistantOutputSinceLastUserInput else { return }

            self.hasEmittedCompletionSinceLastUserInput = true
            let summary = self.latestCompletionSummary.isEmpty ? "❯" : self.latestCompletionSummary

            let event = AgentEvent(
                agentId: self.agentId,
                agentType: self.agentType,
                displayLabel: self.displayLabel,
                eventType: .taskCompleted,
                summary: summary,
                matchedRule: rule.name,
                priority: rule.priority,
                shouldNotify: rule.triggersNotification,
                dedupeKey: "\(self.agentId.uuidString)|\(rule.id.uuidString)|\(self.stableKeyFragment(from: summary))",
                paneId: self.paneId,
                windowId: self.windowId,
                sessionName: self.sessionName
            )
            self.onEvent(event)
        }
    }

    private func scheduleCodexQuietCompletion() {
        guard hasSeenCodexAssistantOutputSinceLastUserInput else { return }
        guard !hasEmittedCompletionSinceLastUserInput else { return }
        guard !latestCodexAssistantSummary.isEmpty else { return }

        codexCompletionTimer?.cancel()
        let summary = latestCodexAssistantSummary
        codexCompletionTimer = Task.detached { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.codexCompletionQuietPeriod * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard !self.hasEmittedCompletionSinceLastUserInput else { return }
            guard self.hasSeenCodexAssistantOutputSinceLastUserInput else { return }

            self.hasEmittedCompletionSinceLastUserInput = true

            let event = AgentEvent(
                agentId: self.agentId,
                agentType: self.agentType,
                displayLabel: self.displayLabel,
                eventType: .taskCompleted,
                summary: "Response completed: \(summary)",
                matchedRule: "Codex: Quiet completion",
                priority: .normal,
                shouldNotify: true,
                dedupeKey: "\(self.agentId.uuidString)|codex-quiet-completion|\(self.stableKeyFragment(from: summary))",
                paneId: self.paneId,
                windowId: self.windowId,
                sessionName: self.sessionName
            )
            self.onEvent(event)
        }
    }

    private func isLikelyCodexAssistantLead(_ line: String) -> Bool {
        line.range(of: #"^\s*•\s+\S.*$"#, options: .regularExpression) != nil
    }

    private func summarizeCodexAssistantLine(_ line: String) -> String {
        line
            .replacingOccurrences(of: #"^\s*•\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeCodexAssistantLine(_ line: String) -> String {
        guard let assistantMarker = line.range(of: "• ") else { return line }
        let prefix = String(line[..<assistantMarker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, isPromptLikeLine(prefix) else { return line }
        return String(line[assistantMarker.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isLikelyCodexChromeLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.contains("openai codex") || lowered.hasPrefix("model:") || lowered.hasPrefix("directory:") {
            return true
        }
        if line.contains("·") && (lowered.contains("% left") || lowered.contains("% used")) {
            return true
        }
        return false
    }

    private func containsMeaningfulUserInput(_ data: Data) -> Bool {
        let bytes = Array(data)
        var index = 0

        while index < bytes.count {
            if let ignoredLength = ignoredTerminalReportLength(in: bytes, startingAt: index) {
                index += ignoredLength
                continue
            }
            return true
        }

        return false
    }

    private func ignoredTerminalReportLength(in bytes: [UInt8], startingAt index: Int) -> Int? {
        let remaining = bytes.count - index
        guard remaining >= 3 else { return nil }
        guard bytes[index] == 0x1B, bytes[index + 1] == 0x5B else { return nil }

        switch bytes[index + 2] {
        case 0x49, 0x4F:
            return 3
        default:
            break
        }

        var cursor = index + 2
        while cursor < bytes.count, isASCIIDigit(bytes[cursor]) {
            cursor += 1
        }
        guard cursor > index + 2, cursor < bytes.count, bytes[cursor] == 0x3B else {
            return nil
        }
        cursor += 1
        let secondNumberStart = cursor
        while cursor < bytes.count, isASCIIDigit(bytes[cursor]) {
            cursor += 1
        }
        guard cursor > secondNumberStart, cursor < bytes.count, bytes[cursor] == 0x52 else {
            return nil
        }
        return cursor - index + 1
    }

    private func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
}
