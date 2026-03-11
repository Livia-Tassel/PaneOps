import Foundation

public enum JumpAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var reason: String? {
        switch self {
        case .available:
            return nil
        case .unavailable(let reason):
            return reason
        }
    }
}

/// Pure policy for deciding whether a row should offer jump actions.
public enum JumpPolicy {
    public static func availability(for agent: AgentInstance) -> JumpAvailability {
        guard agent.status.isActive else {
            return .unavailable(reason: "Agent is no longer active")
        }
        guard !agent.paneId.isEmpty else {
            return .unavailable(reason: "Not in tmux")
        }
        return .available
    }

    public static func availability(for event: AgentEvent) -> JumpAvailability {
        guard !event.paneId.isEmpty else {
            return .unavailable(reason: "No tmux pane available")
        }
        if event.matchedRule.hasPrefix("monitor-expire-") {
            return .unavailable(reason: "Agent pane expired")
        }
        if event.eventType == .taskCompleted {
            return .unavailable(reason: "Task already completed")
        }
        return .available
    }
}
