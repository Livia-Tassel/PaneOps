import Foundation
import SentinelShared

actor MonitorState {
    private var config: AppConfig
    private var agents: [UUID: AgentInstance]
    private var events: [AgentEvent]
    private var dedupeSeenAt: [String: Date] = [:]
    private var subscribers: [Int32: IPCServer.ClientConnection] = [:]
    private let eventStore: EventStore

    init() {
        self.config = AppConfig.load()
        self.eventStore = EventStore(fileURL: AppConfig.eventsFile, maxLines: config.maxStoredEvents)
        self.events = eventStore.loadRecent(config.maxStoredEvents)
        self.agents = MonitorState.loadAgents()
    }

    func handle(_ message: IPCMessage, from connection: IPCServer.ClientConnection) async {
        switch message {
        case .subscribe:
            subscribers[connection.fd] = connection
            do {
                try connection.send(.snapshot(currentSnapshot()))
            } catch {
                subscribers.removeValue(forKey: connection.fd)
                SentinelLogger.ipc.warning("Failed to send snapshot: \(error.localizedDescription)")
            }

        case .register(let agent):
            var updated = agent
            updated.lastActiveAt = Date()
            agents[agent.id] = updated
            saveAgents()
            await broadcast(.register(updated))

        case .heartbeat(let agentId):
            agents[agentId]?.lastActiveAt = Date()
            if agents[agentId]?.status == .stalled {
                agents[agentId]?.status = .running
            }
            saveAgents()

        case .event(let event):
            guard shouldAccept(event: event) else { return }
            var accepted = event
            if !accepted.shouldNotify {
                accepted.acknowledged = true
            }
            apply(event: accepted)
            events.append(accepted)
            if events.count > config.maxStoredEvents {
                events.removeFirst(events.count - config.maxStoredEvents)
            }
            try? eventStore.append(accepted)
            await broadcast(.event(accepted))

        case .deregister(let agentId, let exitCode):
            if agents[agentId] != nil {
                agents[agentId]?.status = (exitCode == 0) ? .completed : .errored
                agents[agentId]?.lastActiveAt = Date()
            }
            saveAgents()
            await broadcast(.deregister(agentId: agentId, exitCode: exitCode))

        case .configUpdate(let newConfig):
            config = newConfig
            try? config.save()
            await broadcast(.configUpdate(config))

        case .snapshot, .ack:
            break
        }
    }

    func tickForStalledAgents() async {
        let now = Date()
        var generated: [AgentEvent] = []

        for agent in agents.values {
            guard agent.status == .running || agent.status == .waiting else { continue }
            let threshold = max(config.stallTimeoutSeconds * 2.0, 10)
            guard now.timeIntervalSince(agent.lastActiveAt) >= threshold else { continue }

            let dedupeKey = "\(agent.id.uuidString)|monitor-heartbeat-stall"
            if let firedAt = dedupeSeenAt[dedupeKey], now.timeIntervalSince(firedAt) < config.eventDedupeWindowSeconds {
                continue
            }
            dedupeSeenAt[dedupeKey] = now

            let event = AgentEvent(
                agentId: agent.id,
                agentType: agent.agentType,
                displayLabel: agent.displayLabel,
                eventType: .stalledOrWaiting,
                summary: "No heartbeat for \(Int(now.timeIntervalSince(agent.lastActiveAt)))s",
                matchedRule: "monitor-heartbeat-timeout",
                priority: .normal,
                shouldNotify: true,
                dedupeKey: dedupeKey,
                timestamp: now,
                paneId: agent.paneId,
                windowId: agent.windowId,
                sessionName: agent.sessionName
            )
            generated.append(event)
            agents[agent.id]?.status = .stalled
            events.append(event)
            try? eventStore.append(event)
        }

        if events.count > config.maxStoredEvents {
            events.removeFirst(events.count - config.maxStoredEvents)
        }
        saveAgents()

        for event in generated {
            await broadcast(.event(event))
        }

        // Opportunistic cleanup
        let oldThreshold = now.addingTimeInterval(-max(config.eventDedupeWindowSeconds * 6, 60))
        dedupeSeenAt = dedupeSeenAt.filter { $0.value >= oldThreshold }
    }

    private func shouldAccept(event: AgentEvent) -> Bool {
        let now = Date()
        if let seenAt = dedupeSeenAt[event.dedupeKey], now.timeIntervalSince(seenAt) < config.eventDedupeWindowSeconds {
            return false
        }
        dedupeSeenAt[event.dedupeKey] = now
        return true
    }

    private func apply(event: AgentEvent) {
        switch event.eventType {
        case .permissionRequested, .inputRequested:
            agents[event.agentId]?.status = .waiting
        case .taskCompleted:
            agents[event.agentId]?.status = .completed
        case .errorDetected:
            agents[event.agentId]?.status = .errored
        case .stalledOrWaiting:
            agents[event.agentId]?.status = .stalled
        }
        agents[event.agentId]?.lastActiveAt = event.timestamp
        saveAgents()
    }

    private func currentSnapshot() -> MonitorSnapshot {
        let sortedAgents = agents.values.sorted { $0.startedAt > $1.startedAt }
        let recentEvents = Array(events.suffix(200))
        return MonitorSnapshot(agents: sortedAgents, events: recentEvents, config: config)
    }

    private func broadcast(_ message: IPCMessage) async {
        guard !subscribers.isEmpty else { return }
        var dead: [Int32] = []
        for (fd, conn) in subscribers {
            do {
                try conn.send(message)
            } catch {
                dead.append(fd)
            }
        }
        for fd in dead {
            subscribers.removeValue(forKey: fd)
        }
    }

    private func saveAgents() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sorted = agents.values.sorted { $0.startedAt > $1.startedAt }
        guard let data = try? encoder.encode(sorted) else { return }
        try? data.write(to: AppConfig.agentsFile, options: .atomic)
    }

    private static func loadAgents() -> [UUID: AgentInstance] {
        guard let data = try? Data(contentsOf: AppConfig.agentsFile) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([AgentInstance].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }
}
