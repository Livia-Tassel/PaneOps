import Foundation
import SentinelShared

/// Pure-function acknowledgment rules for agent events.
///
/// Three acknowledgment scenarios:
/// 1. **Single event**: User explicitly acknowledges via UI (by event ID).
/// 2. **Ended agent**: When an agent expires/deregisters, auto-ack its actionable events
///    (stall, input, permission) — but not completions or errors.
/// 3. **Recovered agent**: When an agent resumes activity, auto-ack specific event types
///    that are no longer relevant (e.g., stall clears on new output).
enum AcknowledgmentPolicy {

    /// Acknowledge a single event by ID. Returns true if the event was found and not already acked.
    @discardableResult
    static func acknowledge(eventId: UUID, in events: inout [AgentEvent]) -> Bool {
        guard let index = events.firstIndex(where: { $0.id == eventId }) else { return false }
        guard !events[index].acknowledged else { return false }
        events[index].acknowledged = true
        return true
    }

    /// Auto-acknowledge actionable events for an agent that has ended (expired/deregistered).
    /// Acks: stalledOrWaiting, inputRequested, permissionRequested.
    /// Skips: taskCompleted, errorDetected (these remain visible).
    static func acknowledgeEndedAgent(_ agentId: UUID, in events: inout [AgentEvent]) -> [UUID] {
        var acked: [UUID] = []
        for index in events.indices {
            guard events[index].agentId == agentId else { continue }
            guard !events[index].acknowledged else { continue }
            switch events[index].eventType {
            case .stalledOrWaiting, .inputRequested, .permissionRequested:
                events[index].acknowledged = true
                acked.append(events[index].id)
            case .taskCompleted, .errorDetected:
                break
            }
        }
        return acked
    }

    /// Auto-acknowledge events of specific types for an agent that has recovered
    /// (resumed activity, heartbeat after stall, etc.).
    static func acknowledgeRecovered(
        agentId: UUID,
        eventTypes: Set<EventType>,
        in events: inout [AgentEvent]
    ) -> [UUID] {
        var acked: [UUID] = []
        for index in events.indices {
            guard events[index].agentId == agentId else { continue }
            guard !events[index].acknowledged else { continue }
            guard eventTypes.contains(events[index].eventType) else { continue }
            events[index].acknowledged = true
            acked.append(events[index].id)
        }
        return acked
    }
}
