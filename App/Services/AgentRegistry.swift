import Foundation
import SwiftUI
import SentinelShared

/// Observable registry of active agents and their events.
@Observable
final class AgentRegistry: ObservableObject, @unchecked Sendable {
    var agents: [UUID: AgentInstance] = [:]
    var events: [AgentEvent] = []
    var config: AppConfig = AppConfig.load()
    var monitorConnected: Bool = false

    var activeAgents: [AgentInstance] {
        agents.values
            .filter { $0.status == .running || $0.status == .waiting || $0.status == .stalled }
            .sorted {
                if $0.lastActiveAt == $1.lastActiveAt {
                    return $0.startedAt > $1.startedAt
                }
                return $0.lastActiveAt > $1.lastActiveAt
            }
    }

    var allAgents: [AgentInstance] {
        agents.values.sorted { $0.startedAt > $1.startedAt }
    }

    var activeAgentIDs: Set<UUID> {
        Set(activeAgents.map(\.id))
    }

    var recentEvents: [AgentEvent] {
        deduplicatedRecentEvents().prefix(50).map { $0 }
    }

    var timelineEvents: [AgentEvent] {
        events.suffix(50).reversed()
    }

    var unacknowledgedCount: Int {
        deduplicatedRecentEvents().filter {
            EventPolicy.isActionable(
                $0,
                now: Date(),
                actionableWindowSeconds: config.actionableEventWindowSeconds,
                activeAgentIDs: activeAgentIDs
            )
        }.count
    }

    func register(_ agent: AgentInstance) {
        agents[agent.id] = agent
    }

    func deregister(agentId: UUID, status: AgentStatus) {
        agents[agentId]?.status = status
    }

    func heartbeat(agentId: UUID) {
        guard var agent = agents[agentId] else { return }
        agent.recordHeartbeat(at: Date())
        agents[agentId] = agent
    }

    func activity(agentId: UUID) {
        guard var agent = agents[agentId] else { return }
        agent.recordOutputActivity(at: Date())
        agents[agentId] = agent
    }

    func resume(agentId: UUID) {
        guard var agent = agents[agentId] else { return }
        agent.recordResume(at: Date())
        agents[agentId] = agent
    }

    func updateStatus(agentId: UUID, event: AgentEvent) {
        guard var agent = agents[agentId] else { return }
        agent.apply(event: event)
        agents[agentId] = agent
    }

    func addEvent(_ event: AgentEvent) {
        var normalized = event
        if normalized.eventType == .taskCompleted {
            normalized.acknowledged = true
        }
        events.append(normalized)
        // Keep max 200 in memory
        if events.count > 200 {
            events.removeFirst(events.count - 200)
        }
    }

    func applySnapshot(_ snapshot: MonitorSnapshot) {
        agents = Dictionary(uniqueKeysWithValues: snapshot.agents.map { ($0.id, $0) })
        let activeIDs = Set(snapshot.agents.filter(\.status.isActive).map(\.id))
        events = EventPolicy.normalizeHistory(
            Array(snapshot.events.suffix(200)),
            now: Date(),
            actionableWindowSeconds: snapshot.config.actionableEventWindowSeconds,
            activeAgentIDs: activeIDs
        )
        config = snapshot.config
    }

    func acknowledgeEvent(id: UUID) {
        if let idx = events.firstIndex(where: { $0.id == id }) {
            events[idx].acknowledged = true
        }
    }

    func acknowledgeAll() {
        for i in events.indices {
            events[i].acknowledged = true
        }
    }

    func acknowledgeAllPendingEventIDs() -> [UUID] {
        let ids = pendingActionableEventIDs()
        for id in ids {
            acknowledgeEvent(id: id)
        }
        return ids
    }

    func removeAgent(id: UUID) {
        agents.removeValue(forKey: id)
    }

    private func deduplicatedRecentEvents() -> [AgentEvent] {
        let recent = Array(events.suffix(200))
        var seen: Set<String> = []
        var deduped: [AgentEvent] = []
        for event in recent.reversed() { // newest first
            let key = event.dedupeKey.isEmpty ? "\(event.id.uuidString)" : event.dedupeKey
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            deduped.append(event)
        }
        return deduped
    }

    private func pendingActionableEventIDs() -> [UUID] {
        deduplicatedRecentEvents().compactMap { event in
            guard EventPolicy.isActionable(
                event,
                now: Date(),
                actionableWindowSeconds: config.actionableEventWindowSeconds,
                activeAgentIDs: activeAgentIDs
            ) else {
                return nil
            }
            return event.id
        }
    }
}
