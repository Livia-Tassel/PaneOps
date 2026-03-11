import Foundation

public enum AgentExpirationReason: String, Sendable {
    case paneMissing
    case sessionMissing
    case heartbeatTimeout
    case noContextTimeout
}

/// Pure liveness rules used by monitor cleanup and startup recovery.
public enum AgentLivenessPolicy {
    public static func expirationReason(
        for agent: AgentInstance,
        now: Date = Date(),
        paneExists: Bool?,
        sessionExists: Bool?,
        config: AppConfig,
        isStartupRecovery: Bool
    ) -> AgentExpirationReason? {
        switch agent.status {
        case .completed, .errored, .expired:
            return nil
        case .running, .waiting, .stalled:
            break
        }

        let inactiveFor = now.timeIntervalSince(agent.lastActiveAt)
        if inactiveFor > config.activeAgentTTLSeconds {
            return .heartbeatTimeout
        }

        if let sessionExists, !sessionExists, !agent.sessionName.isEmpty {
            return .sessionMissing
        }

        if let paneExists, !paneExists, !agent.paneId.isEmpty {
            return .paneMissing
        }

        if agent.paneId.isEmpty {
            let cutoff = isStartupRecovery ? config.staleAgentGraceSeconds : config.activeAgentTTLSeconds
            if inactiveFor > cutoff {
                return .noContextTimeout
            }
        }

        return nil
    }
}
