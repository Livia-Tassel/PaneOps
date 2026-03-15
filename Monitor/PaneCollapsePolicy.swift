import Foundation
import SentinelShared

/// Pane collision resolution and monitor event construction.
///
/// When a new agent registers on a pane that already has an active agent,
/// the old agent must be expired. This policy identifies candidates and
/// provides factory methods for the synthetic events generated during
/// collapse and expiration.
enum PaneCollapsePolicy {

    /// Identify active agents that should be expired because they share a pane
    /// with the incoming registration.
    ///
    /// Returns candidates sorted by startedAt descending (newest first).
    /// Returns empty array if incoming has no paneId.
    static func agentsToCollapse(
        incoming: AgentInstance,
        agents: [UUID: AgentInstance]
    ) -> [AgentInstance] {
        guard !incoming.paneId.isEmpty else { return [] }
        return agents.values
            .filter { candidate in
                candidate.id != incoming.id
                    && candidate.status.isActive
                    && !candidate.paneId.isEmpty
                    && candidate.paneId == incoming.paneId
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Create a synthetic event for when one agent supersedes another on the same pane.
    static func makePaneReplacementEvent(
        for agent: AgentInstance,
        replacement: AgentInstance,
        at now: Date
    ) -> AgentEvent {
        AgentEvent(
            agentId: agent.id,
            agentType: agent.agentType,
            displayLabel: agent.displayLabel,
            eventType: .stalledOrWaiting,
            summary: "Agent expired: superseded by newer registration on pane \(agent.paneId)",
            matchedRule: "monitor-expire-paneReplaced",
            priority: .normal,
            shouldNotify: false,
            dedupeKey: "\(agent.id.uuidString)|expired|paneReplaced|\(replacement.id.uuidString)",
            timestamp: now,
            paneId: agent.paneId,
            windowId: agent.windowId,
            sessionName: agent.sessionName,
            acknowledged: true
        )
    }

    /// Create a synthetic event for when an agent is expired by the monitor
    /// (due to heartbeat timeout, missing pane/session, etc.).
    static func makeExpirationEvent(
        for agent: AgentInstance,
        reason: AgentExpirationReason,
        at now: Date
    ) -> AgentEvent {
        let reasonText: String
        switch reason {
        case .paneMissing:
            reasonText = "pane \(agent.paneId) no longer exists"
        case .sessionMissing:
            reasonText = "session \(agent.sessionName) no longer exists"
        case .heartbeatTimeout:
            reasonText = "heartbeat inactive for too long"
        case .noContextTimeout:
            reasonText = "agent context is stale"
        }

        return AgentEvent(
            agentId: agent.id,
            agentType: agent.agentType,
            displayLabel: agent.displayLabel,
            eventType: .stalledOrWaiting,
            summary: "Agent expired: \(reasonText)",
            matchedRule: "monitor-expire-\(reason.rawValue)",
            priority: .normal,
            shouldNotify: false,
            dedupeKey: "\(agent.id.uuidString)|expired|\(reason.rawValue)",
            timestamp: now,
            paneId: agent.paneId,
            windowId: agent.windowId,
            sessionName: agent.sessionName,
            acknowledged: true
        )
    }
}
