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
    private let promptSymbols: Set<Character> = Set("❯❱›>")
    private let embeddedPromptSymbols: Set<Character> = Set("❯❱›")
    private let promptTrailingCursorGlyphs: Set<Character> = Set("▎▍▌▋▊▉█")
    private let promptIgnorableScalars = CharacterSet(charactersIn: "\u{FE0E}\u{FE0F}\u{200B}\u{200C}\u{200D}\u{2060}")
    private var utf8Decoder = UTF8ChunkDecoder()

    // Rate limiting
    private let rateLimitLinesPerSec: Int
    private var lineCount = 0
    private var lastRateCheck = Date()

    // Stall detection
    private let stallDetector: StallDetector

    // Completion detection
    private let completionDetector: CompletionDetector

    // Line buffer for partial lines
    private var lineBuffer = ""
    private let maxLineBufferChars = 16_384
    private var duplicateSuppressor = DuplicateSuppressor()
    private var hasObservedUserInput = false
    private var lastUserInputAt: Date?

    // Context ring buffer for notification popups (last N stripped lines)
    private var recentContextLines: [String] = []
    private let maxContextLines = 5

    // Output-silence completion detection (fallback when prompt detection misses)
    private let outputSilenceCompletionSeconds: TimeInterval
    private var silenceCompletionTimer: Task<Void, Never>?

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
        outputSilenceCompletionSeconds: TimeInterval = 5,
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) {
        self.agentId = agentId
        self.agentType = agentType
        self.displayLabel = displayLabel
        self.paneId = paneId
        self.windowId = windowId
        self.sessionName = sessionName
        self.ruleEngine = RuleEngine(rules: rules)
        self.rateLimitLinesPerSec = rateLimitLinesPerSec
        self.debugMode = debugMode
        self.suppressInteractiveUntilFirstInput = suppressInteractiveUntilFirstInput
        self.outputSilenceCompletionSeconds = outputSilenceCompletionSeconds
        self.onEvent = onEvent

        if debugMode {
            let path = AppConfig.baseDirectory.appendingPathComponent("debug-output.log").path
            FileManager.default.createFile(atPath: path, contents: nil)
            self.debugFile = FileHandle(forWritingAtPath: path)
            self.debugFile?.seekToEndOfFile()
        } else {
            self.debugFile = nil
        }

        self.stallDetector = StallDetector(timeout: stallTimeout) { [agentId, agentType, displayLabel, paneId, windowId, sessionName, onEvent] in
            let event = AgentEvent(
                agentId: agentId,
                agentType: agentType,
                displayLabel: displayLabel,
                eventType: .stalledOrWaiting,
                summary: "No output for \(Int(stallTimeout))s — agent may be stalled or waiting",
                matchedRule: "stall-detection",
                priority: .normal,
                shouldNotify: true,
                dedupeKey: "\(agentId.uuidString)|stall",
                paneId: paneId,
                windowId: windowId,
                sessionName: sessionName
            )
            onEvent(event)
        }

        // Create agent-specific completion detector
        let isPromptLike: (String) -> Bool = { [promptIgnorableScalars, promptTrailingCursorGlyphs] line in
            let normalized = OutputProcessor.normalizeForMatching(line, ignorableScalars: promptIgnorableScalars, cursorGlyphs: promptTrailingCursorGlyphs)
            return normalized.range(of: #"^\s*[❯❱›>](?:\s+\S.*)?$"#, options: .regularExpression) != nil
        }

        switch agentType {
        case .claude:
            self.completionDetector = ClaudeCompletionDetector(
                quietPeriod: promptCompletionQuietPeriod,
                fallbackMinimumDelay: 0.9
            )
        case .codex:
            let codex = CodexCompletionDetector(
                quietPeriod: codexCompletionQuietPeriod,
                isPromptLike: isPromptLike
            )
            codex.onQuietCompletion = { [agentId, agentType, displayLabel, paneId, windowId, sessionName, onEvent] summary in
                let event = AgentEvent(
                    agentId: agentId,
                    agentType: agentType,
                    displayLabel: displayLabel,
                    eventType: .taskCompleted,
                    summary: "Response completed: \(summary)",
                    matchedRule: "Codex: Quiet completion",
                    priority: .normal,
                    shouldNotify: true,
                    dedupeKey: "\(agentId.uuidString)|codex-quiet-completion|\(String(summary.lowercased().prefix(120)))",
                    paneId: paneId,
                    windowId: windowId,
                    sessionName: sessionName
                )
                onEvent(event)
            }
            self.completionDetector = codex
        default:
            self.completionDetector = ClaudeCompletionDetector(
                quietPeriod: promptCompletionQuietPeriod,
                fallbackMinimumDelay: 0.9
            )
        }
    }

    /// Process a chunk of raw PTY output.
    public func processData(_ data: Data) {
        guard !data.isEmpty else { return }

        let now = Date()
        stallDetector.reset()

        let text = utf8Decoder.decode(data)
        guard !text.isEmpty else { return }
        lineBuffer += text
        if lineBuffer.count > maxLineBufferChars {
            lineBuffer = String(lineBuffer.suffix(maxLineBufferChars))
        }

        var lines = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.removeLast()

        lineCount += lines.count
        if now.timeIntervalSince(lastRateCheck) >= 1.0 {
            lineCount = lines.count
            lastRateCheck = now
        }

        if lineCount > rateLimitLinesPerSec {
            duplicateSuppressor.trimForBurst()
        }
        for line in lines {
            processLine(line)
        }

        processBufferedCandidate()
        scheduleSilenceCompletionIfNeeded()
    }

    /// Flush any remaining buffered content (call when PTY closes).
    public func flush() {
        let remaining = utf8Decoder.flush()
        if !remaining.isEmpty {
            lineBuffer += remaining
        }
        if !lineBuffer.isEmpty {
            processLine(lineBuffer)
            lineBuffer = ""
        }
        stallDetector.cancel()
        silenceCompletionTimer?.cancel()
        completionDetector.cancelTimers()
    }

    /// Update rules (e.g., from config change).
    public func updateRules(_ rules: [Rule]) {
        ruleEngine.updateRules(rules)
    }

    /// Let the processor know the user has typed into the PTY.
    @discardableResult
    public func noteUserInput(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        guard containsMeaningfulUserInput(data) else { return false }

        lastUserInputAt = Date()
        stallDetector.reset()
        silenceCompletionTimer?.cancel()
        completionDetector.resetTurn()

        guard suppressInteractiveUntilFirstInput, !hasObservedUserInput else { return true }
        hasObservedUserInput = true
        return true
    }

    // MARK: - Private

    private func processLine(_ rawLine: String) {
        let stripped = normalizedLineForMatching(stripper.strip(rawLine))
        guard !stripped.isEmpty else { return }

        // Record for context display in notification popups
        recordContextLine(stripped)

        if isLikelyLocalInputEcho(stripped) { return }
        let embeddedPrompt = embeddedPromptSplit(from: stripped)
        let observationLine = embeddedPrompt?.prefix ?? stripped
        let prompt = isPromptLikeLine(observationLine)
        if embeddedPrompt != nil {
            completionDetector.observeLine(
                completionDetector.normalizeLine(observationLine),
                matchedEventType: nil,
                isPromptLike: prompt
            )
        }
        let lineForMatch = embeddedPrompt?.prompt ?? stripped

        if debugMode, let fh = debugFile {
            let logLine = "[STRIPPED] \(stripped)\n"
            fh.write(logLine.data(using: .utf8)!)
        }

        let match = ruleEngine.match(line: lineForMatch, agentType: agentType, agentId: agentId)
        if let match {
            if shouldSuppressInteractiveEventBeforeInput(match.rule.eventType) { return }
            if match.rule.eventType == .taskCompleted,
               completionDetector.shouldSuppressCompletion(
                   summary: lineForMatch,
                   isPromptEcho: isLikelyPromptEchoBeforeAssistantOutput(lineForMatch)
               ) { return }
            if shouldSuppressLikelyMetaOrControlLine(lineForMatch, eventType: match.rule.eventType) { return }
            if match.rule.eventType == .taskCompleted,
               isPromptLikeLine(lineForMatch),
               completionDetector.handleDeferredCompletion(rule: match.rule, onEmit: { [weak self] rule, summary in
                   self?.emitDeferredCompletion(rule: rule, summary: summary)
               }) { return }
            guard !shouldSuppressRepeatedLine(lineForMatch) else { return }
            emitMatchedEvent(match, summary: lineForMatch)
        }

        // Observe for completion tracking (Codex uses its own observation in observeLine)
        let normalizedObs = completionDetector.normalizeLine(observationLine)
        completionDetector.observeLine(normalizedObs, matchedEventType: match?.rule.eventType, isPromptLike: isPromptLikeLine(normalizedObs))
    }

    private func processBufferedCandidate() {
        let stripped = normalizedLineForMatching(stripper.strip(lineBuffer))
        guard !stripped.isEmpty else { return }
        if isLikelyLocalInputEcho(stripped) {
            lineBuffer = ""
            return
        }
        let embeddedPrompt = embeddedPromptSplit(from: stripped)
        let observationLine = embeddedPrompt?.prefix ?? stripped
        if embeddedPrompt != nil {
            let normalizedObs = completionDetector.normalizeLine(observationLine)
            completionDetector.observeLine(normalizedObs, matchedEventType: nil, isPromptLike: isPromptLikeLine(normalizedObs))
        }
        let candidateForMatch: String
        if let embeddedPrompt {
            candidateForMatch = embeddedPrompt.prompt
        } else if stripped.count > 120 {
            guard let promptTail = promptTailCandidate(from: stripped) else { return }
            candidateForMatch = promptTail
        } else {
            candidateForMatch = stripped
        }

        let match = ruleEngine.match(line: candidateForMatch, agentType: agentType, agentId: agentId)
        if let match,
           match.rule.eventType == .inputRequested
            || match.rule.eventType == .permissionRequested
            || match.rule.eventType == .taskCompleted
        {
            if shouldSuppressInteractiveEventBeforeInput(match.rule.eventType) {
                consumeBufferedPromptIfNeeded(candidateForMatch)
                return
            }
            if match.rule.eventType == .taskCompleted,
               completionDetector.shouldSuppressCompletion(
                   summary: candidateForMatch,
                   isPromptEcho: isLikelyPromptEchoBeforeAssistantOutput(candidateForMatch)
               ) {
                consumeBufferedPromptIfNeeded(candidateForMatch)
                return
            }
            if shouldSuppressLikelyMetaOrControlLine(candidateForMatch, eventType: match.rule.eventType) { return }
            if match.rule.eventType == .taskCompleted,
               isPromptLikeLine(candidateForMatch),
               completionDetector.handleDeferredCompletion(rule: match.rule, onEmit: { [weak self] rule, summary in
                   self?.emitDeferredCompletion(rule: rule, summary: summary)
               }) {
                consumeBufferedPromptIfNeeded(candidateForMatch)
                return
            }
            if shouldSuppressRepeatedLine(candidateForMatch) {
                consumeBufferedPromptIfNeeded(candidateForMatch)
                return
            }
            emitMatchedEvent(match, summary: candidateForMatch)
            consumeBufferedPromptIfNeeded(candidateForMatch)
        }

        let normalizedObs = completionDetector.normalizeLine(observationLine)
        completionDetector.observeLine(normalizedObs, matchedEventType: match?.rule.eventType, isPromptLike: isPromptLikeLine(normalizedObs))
    }

    private func shouldSuppressRepeatedLine(_ line: String) -> Bool {
        duplicateSuppressor.shouldSuppress(line, key: stableKeyFragment(from: line))
    }

    private func stableKeyFragment(from line: String) -> String {
        String(line.lowercased().prefix(120))
    }

    private func consumeBufferedPromptIfNeeded(_ line: String) {
        if isPromptLikeLine(line) {
            lineBuffer = ""
        }
    }

    private func recordContextLine(_ line: String) {
        recentContextLines.append(line)
        if recentContextLines.count > maxContextLines {
            recentContextLines.removeFirst(recentContextLines.count - maxContextLines)
        }
    }

    private func contextLinesForEvent(_ eventType: EventType) -> [String]? {
        switch eventType {
        case .permissionRequested, .inputRequested, .taskCompleted:
            return recentContextLines.isEmpty ? nil : recentContextLines
        case .errorDetected, .stalledOrWaiting:
            return nil
        }
    }

    private func scheduleSilenceCompletionIfNeeded() {
        // Only fire after user input started a turn and assistant produced output
        guard lastUserInputAt != nil else { return }
        guard completionDetector.hasSeenAssistantOutput else { return }
        guard !completionDetector.hasEmittedCompletion else { return }
        guard outputSilenceCompletionSeconds > 0 else { return }

        silenceCompletionTimer?.cancel()
        silenceCompletionTimer = Task.detached { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.outputSilenceCompletionSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard !self.completionDetector.hasEmittedCompletion else { return }
            guard self.completionDetector.hasSeenAssistantOutput else { return }

            self.completionDetector.markCompletionEmitted()
            let summary = self.completionDetector.latestSummary.isEmpty
                ? "Response completed"
                : self.completionDetector.latestSummary

            let event = AgentEvent(
                agentId: self.agentId,
                agentType: self.agentType,
                displayLabel: self.displayLabel,
                eventType: .taskCompleted,
                summary: summary,
                matchedRule: "output-silence-completion",
                priority: .normal,
                shouldNotify: true,
                dedupeKey: "\(self.agentId.uuidString)|silence-completion|\(self.stableKeyFragment(from: summary))",
                paneId: self.paneId,
                windowId: self.windowId,
                sessionName: self.sessionName,
                contextLines: self.recentContextLines.isEmpty ? nil : self.recentContextLines
            )
            self.onEvent(event)
        }
    }

    private func emitMatchedEvent(_ match: RuleEngine.MatchResult, summary: String) {
        let eventSummary: String
        if match.rule.eventType == .taskCompleted, isPromptLikeLine(summary) {
            if let resolved = completionDetector.resolvedSummary(isPromptLike: true) {
                eventSummary = resolved
            } else if !completionDetector.latestSummary.isEmpty {
                eventSummary = completionDetector.latestSummary
            } else {
                eventSummary = summary
            }
        } else {
            eventSummary = summary
        }

        if match.rule.eventType == .taskCompleted {
            completionDetector.markCompletionEmitted()
            silenceCompletionTimer?.cancel()
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
            sessionName: sessionName,
            contextLines: contextLinesForEvent(match.rule.eventType)
        )
        onEvent(event)
    }

    private func emitDeferredCompletion(rule: Rule, summary: String) {
        let event = AgentEvent(
            agentId: agentId,
            agentType: agentType,
            displayLabel: displayLabel,
            eventType: .taskCompleted,
            summary: summary,
            matchedRule: rule.name,
            priority: rule.priority,
            shouldNotify: rule.triggersNotification,
            dedupeKey: "\(agentId.uuidString)|\(rule.id.uuidString)|\(stableKeyFragment(from: summary))",
            paneId: paneId,
            windowId: windowId,
            sessionName: sessionName,
            contextLines: contextLinesForEvent(.taskCompleted)
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
        return lowered.contains("[?2004h")
            || lowered.contains("[?1004h")
            || lowered.contains("[?2026h")
            || lowered.contains("[>7u")
            || lowered.contains("[?u")
    }

    private func isLikelyRuleDescriptionLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let metaMarkers = [
            "rule", "rules", "regex", "keyword", "pattern", "event type",
            "input requested", "permission requested", "task completed",
            "detect events", "built-in", "builtin", "example", "examples",
            "内置示例", "匹配规则", "关键词", "正则", "事件类型", "提示词",
        ]
        if metaMarkers.contains(where: { lowered.contains($0) }) { return true }
        if lowered.contains("allow|") || lowered.contains("|allow") || lowered.contains("proceed|") { return true }
        return false
    }

    private func isLikelyLocalInputEcho(_ line: String) -> Bool {
        isLikelyPromptEchoBeforeAssistantOutput(line)
    }

    private func isLikelyPromptEchoBeforeAssistantOutput(_ line: String) -> Bool {
        guard let lastUserInputAt else { return false }
        guard !completionDetector.hasSeenAssistantOutput else { return false }
        guard Date().timeIntervalSince(lastUserInputAt) <= 0.35 else { return false }
        return isPromptLikeLine(line)
    }

    private func isPromptLikeLine(_ line: String) -> Bool {
        let normalized = normalizedLineForMatching(line)
        return normalized.range(of: #"^\s*[❯❱›>](?:\s+\S.*)?$"#, options: .regularExpression) != nil
    }

    private func normalizedLineForMatching(_ line: String) -> String {
        Self.normalizeForMatching(line, ignorableScalars: promptIgnorableScalars, cursorGlyphs: promptTrailingCursorGlyphs)
    }

    static func normalizeForMatching(_ line: String, ignorableScalars: CharacterSet, cursorGlyphs: Set<Character>) -> String {
        var normalizedScalars: [UnicodeScalar] = []
        normalizedScalars.reserveCapacity(line.unicodeScalars.count)
        for scalar in line.unicodeScalars where !ignorableScalars.contains(scalar) {
            if scalar == "\u{00A0}" || scalar == "\u{202F}" {
                normalizedScalars.append(" ")
            } else {
                normalizedScalars.append(scalar)
            }
        }

        var normalized = String(String.UnicodeScalarView(normalizedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = normalized.last, cursorGlyphs.contains(last) {
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }

    private func promptTailCandidate(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, promptSymbols.contains(last) else { return nil }
        let prefix = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty || isLikelySeparatorLine(prefix) { return String(last) }
        if prefix.range(of: #"[-_=~─━═]{3,}\s*$"#, options: .regularExpression) != nil { return String(last) }
        return nil
    }

    private func embeddedPromptSplit(from line: String) -> (prompt: String, prefix: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let promptIndex = trimmed.lastIndex(where: { embeddedPromptSymbols.contains($0) }) else { return nil }
        let prompt = String(trimmed[promptIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPromptLikeLine(prompt) else { return nil }
        let prefix = String(trimmed[..<promptIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return nil }
        return (prompt, prefix)
    }

    private func isLikelySeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        let separators = CharacterSet(charactersIn: "-_=~─━═")
        return trimmed.unicodeScalars.allSatisfy { separators.contains($0) }
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
        while cursor < bytes.count, isASCIIDigit(bytes[cursor]) { cursor += 1 }
        guard cursor > index + 2, cursor < bytes.count, bytes[cursor] == 0x3B else { return nil }
        cursor += 1
        let secondNumberStart = cursor
        while cursor < bytes.count, isASCIIDigit(bytes[cursor]) { cursor += 1 }
        guard cursor > secondNumberStart, cursor < bytes.count, bytes[cursor] == 0x52 else { return nil }
        return cursor - index + 1
    }

    private func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
}
