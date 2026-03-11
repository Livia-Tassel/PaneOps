import Foundation

/// Event policy utilities for UI counters and normalization.
public enum EventPolicy {
    public static func isActionable(
        _ event: AgentEvent,
        now: Date = Date(),
        actionableWindowSeconds: TimeInterval
    ) -> Bool {
        guard !event.acknowledged else { return false }
        guard now.timeIntervalSince(event.timestamp) <= actionableWindowSeconds else { return false }

        switch event.eventType {
        case .permissionRequested, .inputRequested, .errorDetected, .stalledOrWaiting:
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
        actionableWindowSeconds: TimeInterval
    ) -> [AgentEvent] {
        events.map { event in
            var normalized = event
            if normalized.eventType == .taskCompleted {
                normalized.acknowledged = true
                return normalized
            }
            if !isActionable(normalized, now: now, actionableWindowSeconds: actionableWindowSeconds) {
                normalized.acknowledged = true
            }
            return normalized
        }
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
