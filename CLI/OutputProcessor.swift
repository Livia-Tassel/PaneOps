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
    private var lastBufferedCandidateKey = ""
    private var lastBufferedCandidateAt = Date.distantPast

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
        guard let text = String(data: data, encoding: .utf8) else { return }
        lineBuffer += text
        if lineBuffer.count > maxLineBufferChars {
            lineBuffer = String(lineBuffer.suffix(maxLineBufferChars))
        }

        // Split on newlines, keep the last partial line in buffer
        var lines = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.removeLast() // May be empty string if text ended with \n

        let now = Date()
        lastOutputTime = now
        stallFired = false
        resetStallTimer()

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
        if !lineBuffer.isEmpty {
            processLine(lineBuffer)
            lineBuffer = ""
        }
        stallTimer?.cancel()
    }

    /// Update rules (e.g., from config change).
    public func updateRules(_ rules: [Rule]) {
        ruleEngine.updateRules(rules)
    }

    // MARK: - Private

    private func processLine(_ rawLine: String) {
        let stripped = stripper.strip(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return }
        guard !shouldSuppressRepeatedLine(stripped) else { return }

        // Debug: log all stripped lines to file
        if debugMode, let fh = debugFile {
            let logLine = "[STRIPPED] \(stripped)\n"
            fh.write(logLine.data(using: .utf8)!)
        }

        if let match = ruleEngine.match(line: stripped, agentType: agentType, agentId: agentId) {
            emitMatchedEvent(match, summary: stripped)
        }
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

    private func processBufferedCandidate() {
        let stripped = stripper.strip(lineBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return }
        guard stripped.count <= 120 else { return }

        guard let match = ruleEngine.match(line: stripped, agentType: agentType, agentId: agentId) else {
            return
        }
        guard match.rule.eventType == .inputRequested
            || match.rule.eventType == .permissionRequested
            || match.rule.eventType == .taskCompleted
        else {
            return
        }

        let now = Date()
        let key = "\(match.rule.id.uuidString)|\(stableKeyFragment(from: stripped))"
        if key == lastBufferedCandidateKey, now.timeIntervalSince(lastBufferedCandidateAt) < 1.5 {
            return
        }
        lastBufferedCandidateKey = key
        lastBufferedCandidateAt = now

        emitMatchedEvent(match, summary: stripped)
    }

    private func emitMatchedEvent(_ match: RuleEngine.MatchResult, summary: String) {
        if debugMode, let fh = debugFile {
            let logLine = "[MATCH] rule=\(match.rule.name) type=\(match.rule.eventType.rawValue)\n"
            fh.write(logLine.data(using: .utf8)!)
        }

        let event = AgentEvent(
            agentId: agentId,
            agentType: agentType,
            displayLabel: displayLabel,
            eventType: match.rule.eventType,
            summary: summary,
            matchedRule: match.rule.name,
            priority: match.rule.priority,
            shouldNotify: match.rule.triggersNotification,
            dedupeKey: "\(agentId.uuidString)|\(match.rule.id.uuidString)|\(stableKeyFragment(from: summary))",
            paneId: paneId,
            windowId: windowId,
            sessionName: sessionName
        )
        onEvent(event)
    }
}
