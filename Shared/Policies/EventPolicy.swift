import Foundation

/// Event policy utilities for UI counters and normalization.
public enum EventPolicy {
    public static func isActionable(
        _ event: AgentEvent,
        now: Date = Date(),
        actionableWindowSeconds: TimeInterval,
        activeAgentIDs: Set<UUID>? = nil
    ) -> Bool {
        guard !event.acknowledged else { return false }
        guard now.timeIntervalSince(event.timestamp) <= actionableWindowSeconds else { return false }

        switch event.eventType {
        case .permissionRequested, .inputRequested, .errorDetected, .stalledOrWaiting:
            if event.eventType != .errorDetected,
               let activeAgentIDs,
               !activeAgentIDs.contains(event.agentId) {
                return false
            }
            return true
        case .taskCompleted:
            return false
        }
    }

    /// Normalize historical events after loading, so old completed/non-actionable events
    /// do not keep polluting the actionable badge.
    public static func normalizeHistory(
        _ events: [AgentEvent],
        now: Date = Date(),
        actionableWindowSeconds: TimeInterval,
        activeAgentIDs: Set<UUID>? = nil
    ) -> [AgentEvent] {
        events.map { event in
            var normalized = event
            if normalized.eventType == .taskCompleted {
                normalized.acknowledged = true
                return normalized
            }
            if isLegacyClaudePromptCompletion(normalized) {
                normalized.acknowledged = true
                return normalized
            }
            if !isActionable(
                normalized,
                now: now,
                actionableWindowSeconds: actionableWindowSeconds,
                activeAgentIDs: activeAgentIDs
            ) {
                normalized.acknowledged = true
            }
            return normalized
        }
    }

    private static func isLegacyClaudePromptCompletion(_ event: AgentEvent) -> Bool {
        guard event.eventType == .inputRequested, event.agentType == .claude else { return false }
        let summary = canonicalSummary(event.summary)
        return event.matchedRule == "Claude: Prompt ready (❯)" || summary == "❯"
    }

    public static func canonicalSummary(_ summary: String) -> String {
        summary
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            .prefix(160)
            .description
    }
}
