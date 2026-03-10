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
            .sorted { $0.startedAt < $1.startedAt }
    }

    var allAgents: [AgentInstance] {
        agents.values.sorted { $0.startedAt > $1.startedAt }
    }

    var recentEvents: [AgentEvent] {
        events.suffix(50).reversed()
    }

    var unacknowledgedCount: Int {
        events.filter { !$0.acknowledged }.count
    }

    func register(_ agent: AgentInstance) {
        agents[agent.id] = agent
    }

    func deregister(agentId: UUID, status: AgentStatus) {
        agents[agentId]?.status = status
    }

    func heartbeat(agentId: UUID) {
        agents[agentId]?.lastActiveAt = Date()
    }

    func updateStatus(agentId: UUID, event: AgentEvent) {
        switch event.eventType {
        case .permissionRequested, .inputRequested:
            agents[agentId]?.status = .waiting
        case .errorDetected:
            agents[agentId]?.status = .errored
        case .stalledOrWaiting:
            agents[agentId]?.status = .stalled
        case .taskCompleted:
            agents[agentId]?.status = .completed
        }
        agents[agentId]?.lastActiveAt = event.timestamp
    }

    func addEvent(_ event: AgentEvent) {
        events.append(event)
        // Keep max 200 in memory
        if events.count > 200 {
            events.removeFirst(events.count - 200)
        }
    }

    func applySnapshot(_ snapshot: MonitorSnapshot) {
        agents = Dictionary(uniqueKeysWithValues: snapshot.agents.map { ($0.id, $0) })
        events = Array(snapshot.events.suffix(200))
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

    func removeAgent(id: UUID) {
        agents.removeValue(forKey: id)
    }
}
