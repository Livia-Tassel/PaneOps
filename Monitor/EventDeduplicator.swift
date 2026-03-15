import Foundation
import SentinelShared

/// Manages event deduplication and stall alert gating for the monitor daemon.
///
/// Two independent mechanisms work together:
/// 1. **Time-windowed dedup**: Events with the same canonical key within a type-specific
///    window are rejected. Windows: stall=60s, completion=1s, others=configurable (default 6s).
/// 2. **Stall alert gate**: After a stall-detection event fires for an agent, subsequent
///    stall events are blocked until the agent recovers (activity or resume).
struct EventDeduplicator {
    private var seenAt: [String: Date] = [:]
    private var stallAlertedAgentIDs: Set<UUID> = []

    /// Check if an event should be accepted (not a duplicate).
    /// If accepted, records the event in the dedup map.
    mutating func shouldAccept(event: AgentEvent, config: AppConfig, now: Date) -> Bool {
        // Stall alert gate: block repeated stall-detection events until recovery
        if event.eventType == .stalledOrWaiting,
           event.matchedRule == "stall-detection",
           stallAlertedAgentIDs.contains(event.agentId) {
            return false
        }

        let dedupeKey = canonicalDedupeKey(for: event)
        let window: TimeInterval
        switch event.eventType {
        case .stalledOrWaiting:
            window = max(60, config.eventDedupeWindowSeconds)
        case .taskCompleted:
            window = 1
        case .permissionRequested, .inputRequested, .errorDetected:
            window = config.eventDedupeWindowSeconds
        }

        if let seen = seenAt[dedupeKey], now.timeIntervalSince(seen) < window {
            return false
        }
        seenAt[dedupeKey] = now
        return true
    }

    /// Update the stall alert gate after an event is accepted.
    /// Stall-detection events arm the gate; all other events disarm it.
    mutating func updateStallAlertGate(for event: AgentEvent) {
        if event.eventType == .stalledOrWaiting, event.matchedRule == "stall-detection" {
            stallAlertedAgentIDs.insert(event.agentId)
            return
        }
        stallAlertedAgentIDs.remove(event.agentId)
    }

    /// Clear the stall alert gate for a specific agent (on activity, resume, deregister).
    mutating func clearStallAlert(for agentId: UUID) {
        stallAlertedAgentIDs.remove(agentId)
    }

    /// Evict stale entries from the dedup map. Called periodically.
    mutating func cleanup(now: Date, dedupeWindowSeconds: TimeInterval) {
        let threshold = now.addingTimeInterval(-max(dedupeWindowSeconds * 12, 300))
        seenAt = seenAt.filter { $0.value >= threshold }
    }

    /// Clear all dedup state (for maintenance).
    mutating func clearAll() {
        seenAt.removeAll()
        stallAlertedAgentIDs.removeAll()
    }

    // MARK: - Private

    private func canonicalDedupeKey(for event: AgentEvent) -> String {
        let pane = event.paneId.isEmpty ? "none" : event.paneId
        let canonicalSummary = EventPolicy.canonicalSummary(event.summary)
        return "\(event.agentId.uuidString)|\(event.eventType.rawValue)|\(pane)|\(canonicalSummary)"
    }
}
