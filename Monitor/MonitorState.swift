import Foundation
import SentinelShared

actor MonitorState {
    private var config: AppConfig
    private var agents: [UUID: AgentInstance]
    private var events: [AgentEvent]
    private var dedupeSeenAt: [String: Date] = [:]
    private var stallAlertedAgentIDs: Set<UUID> = []
    private var subscribers: [Int32: IPCServer.ClientConnection] = [:]

    private let tmux: TmuxClient
    private let nowProvider: @Sendable () -> Date
    private let eventStore: EventStore

    init(
        tmux: TmuxClient = TmuxClient(),
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tmux = tmux
        self.nowProvider = nowProvider
        self.config = AppConfig.load()
        self.eventStore = EventStore(fileURL: AppConfig.eventsFile, maxLines: config.maxStoredEvents)
        self.agents = MonitorState.loadAgents()

        let now = nowProvider()
        let loadedEvents = eventStore.loadRecent(config.maxStoredEvents)
        let startupActiveAgentIDs = Set(self.agents.values.filter(\.status.isActive).map(\.id))
        self.events = EventPolicy.normalizeHistory(
            loadedEvents,
            now: now,
            actionableWindowSeconds: config.actionableEventWindowSeconds,
            activeAgentIDs: startupActiveAgentIDs
        )
        var generated: [AgentEvent] = []
        var changed = Self.hasAcknowledgementChanges(original: loadedEvents, normalized: self.events)

        for agent in self.agents.values {
            let paneExists: Bool? = agent.paneId.isEmpty ? nil : tmux.paneExists(agent.paneId)
            let sessionExists: Bool? = agent.sessionName.isEmpty ? nil : tmux.sessionExists(agent.sessionName)
            let reason = AgentLivenessPolicy.expirationReason(
                for: agent,
                now: now,
                paneExists: paneExists,
                sessionExists: sessionExists,
                config: self.config,
                isStartupRecovery: true
            )
            guard let reason else { continue }
            guard agent.status != .expired else { continue }

            self.agents[agent.id]?.status = .expired
            self.agents[agent.id]?.lastActiveAt = now
            changed = true

            let event = Self.makeExpirationEvent(for: agent, reason: reason, at: now)
            generated.append(event)
        }

        if !generated.isEmpty {
            for event in generated {
                self.events.append(event)
                try? self.eventStore.append(event)
            }
            changed = true
        }

        let preNormalizedEvents = self.events
        let activeAgentIDs = Set(self.agents.values.filter(\.status.isActive).map(\.id))
        self.events = EventPolicy.normalizeHistory(
            preNormalizedEvents,
            now: now,
            actionableWindowSeconds: self.config.actionableEventWindowSeconds,
            activeAgentIDs: activeAgentIDs
        )
        if Self.hasAcknowledgementChanges(original: preNormalizedEvents, normalized: self.events) {
            changed = true
        }

        if self.events.count > self.config.maxStoredEvents {
            self.events.removeFirst(self.events.count - self.config.maxStoredEvents)
            changed = true
        }

        if changed {
            Self.persistAgents(agents)
            try? eventStore.rewrite(self.events)
        }
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
            updated.lastActiveAt = nowProvider()
            updated.status = .running
            agents[agent.id] = updated
            stallAlertedAgentIDs.remove(agent.id)
            saveAgents()
            await broadcast(.register(updated))

        case .heartbeat(let agentId):
            agents[agentId]?.lastActiveAt = nowProvider()
            if agents[agentId]?.status == .stalled || agents[agentId]?.status == .expired {
                agents[agentId]?.status = .running
            }
            saveAgents()

        case .event(let event):
            guard shouldAccept(event: event) else { return }

            var accepted = event
            if accepted.eventType == .taskCompleted || !accepted.shouldNotify {
                accepted.acknowledged = true
            }
            updateStallAlertGate(for: accepted)

            apply(event: accepted)
            events.append(accepted)
            trimEventsIfNeeded()

            try? eventStore.append(accepted)
            await broadcast(.event(accepted))

        case .deregister(let agentId, let exitCode):
            let now = nowProvider()
            if exitCode == 0, shouldEmitSyntheticCompletion(for: agentId, now: now), let agent = agents[agentId] {
                var completionEvent = AgentEvent(
                    agentId: agent.id,
                    agentType: agent.agentType,
                    displayLabel: agent.displayLabel,
                    eventType: .taskCompleted,
                    summary: "Task completed (process exited successfully)",
                    matchedRule: "monitor-exit-success",
                    priority: .normal,
                    shouldNotify: true,
                    dedupeKey: "\(agent.id.uuidString)|taskCompleted|exit-success",
                    timestamp: now,
                    paneId: agent.paneId,
                    windowId: agent.windowId,
                    sessionName: agent.sessionName,
                    acknowledged: true
                )

                if shouldAccept(event: completionEvent) {
                    completionEvent.acknowledged = true
                    apply(event: completionEvent)
                    events.append(completionEvent)
                    trimEventsIfNeeded()
                    try? eventStore.append(completionEvent)
                    await broadcast(.event(completionEvent))
                }
            }

            if agents[agentId] != nil {
                agents[agentId]?.status = (exitCode == 0) ? .completed : .errored
                agents[agentId]?.lastActiveAt = now
            }
            stallAlertedAgentIDs.remove(agentId)
            let ackedIds = acknowledgeEndedAgentEvents(agentId: agentId)
            saveAgents()
            if !ackedIds.isEmpty {
                persistEventsSnapshot()
                for eventId in ackedIds {
                    await broadcast(.ack(messageId: eventId))
                }
            }
            await broadcast(.deregister(agentId: agentId, exitCode: exitCode))

        case .configUpdate(let newConfig):
            config = newConfig
            try? config.save()
            let activeAgentIDs = Set(agents.values.filter(\.status.isActive).map(\.id))
            events = EventPolicy.normalizeHistory(
                events,
                now: nowProvider(),
                actionableWindowSeconds: config.actionableEventWindowSeconds,
                activeAgentIDs: activeAgentIDs
            )
            trimEventsIfNeeded()
            persistEventsSnapshot()
            saveAgents()
            await broadcast(.configUpdate(config))

        case .maintenance(let request):
            do {
                try performMaintenance(request.action)
            } catch {
                SentinelLogger.storage.warning("Maintenance action \(request.action.rawValue) failed: \(error.localizedDescription)")
            }
            await broadcast(.snapshot(currentSnapshot()))

        case .ack(let messageId):
            if acknowledgeEvent(id: messageId) {
                persistEventsSnapshot()
                await broadcast(.ack(messageId: messageId))
            }

        case .snapshot:
            break
        }
    }

    /// Periodic maintenance: expire stale active agents and emit silent structured events.
    func tickForStalledAgents() async {
        let now = nowProvider()
        var generated: [AgentEvent] = []
        var ackedIds: [UUID] = []
        var stateChanged = false

        for agent in agents.values {
            guard let reason = expirationReason(for: agent, now: now, isStartupRecovery: false) else { continue }
            guard agent.status != .expired else { continue }

            agents[agent.id]?.status = .expired
            agents[agent.id]?.lastActiveAt = now
            stateChanged = true

            let event = expirationEvent(for: agent, reason: reason, at: now)
            if shouldAccept(event: event) {
                events.append(event)
                generated.append(event)
                try? eventStore.append(event)
            }
            ackedIds.append(contentsOf: acknowledgeEndedAgentEvents(agentId: agent.id))
        }

        if stateChanged || !ackedIds.isEmpty {
            trimEventsIfNeeded()
            saveAgents()
            persistEventsSnapshot()
        }

        for eventId in ackedIds {
            await broadcast(.ack(messageId: eventId))
        }

        for event in generated {
            await broadcast(.event(event))
        }

        cleanupDedupeMap(now: now)
    }

    // MARK: - Event semantics

    private func shouldAccept(event: AgentEvent) -> Bool {
        if event.eventType == .stalledOrWaiting,
           event.matchedRule == "stall-detection",
           stallAlertedAgentIDs.contains(event.agentId) {
            return false
        }

        let now = nowProvider()
        let dedupeKey = canonicalDedupeKey(for: event)
        let window: TimeInterval
        switch event.eventType {
        case .stalledOrWaiting:
            window = max(60, config.eventDedupeWindowSeconds)
        case .taskCompleted:
            // Keep completion notifications responsive for rapid Q&A turns.
            window = 1
        case .permissionRequested, .inputRequested, .errorDetected:
            window = config.eventDedupeWindowSeconds
        }

        if let seenAt = dedupeSeenAt[dedupeKey], now.timeIntervalSince(seenAt) < window {
            return false
        }
        dedupeSeenAt[dedupeKey] = now
        return true
    }

    private func updateStallAlertGate(for event: AgentEvent) {
        if event.eventType == .stalledOrWaiting, event.matchedRule == "stall-detection" {
            stallAlertedAgentIDs.insert(event.agentId)
            return
        }
        stallAlertedAgentIDs.remove(event.agentId)
    }

    private func canonicalDedupeKey(for event: AgentEvent) -> String {
        let pane = event.paneId.isEmpty ? "none" : event.paneId
        let canonicalSummary = EventPolicy.canonicalSummary(event.summary)
        return "\(event.agentId.uuidString)|\(event.eventType.rawValue)|\(pane)|\(canonicalSummary)"
    }

    private func apply(event: AgentEvent) {
        switch event.eventType {
        case .permissionRequested, .inputRequested:
            agents[event.agentId]?.status = .waiting
        case .taskCompleted:
            agents[event.agentId]?.status = .running
        case .errorDetected:
            agents[event.agentId]?.status = .errored
        case .stalledOrWaiting:
            agents[event.agentId]?.status = .stalled
        }
        agents[event.agentId]?.lastActiveAt = event.timestamp
        saveAgents()
    }

    // MARK: - Expiration

    private func expirationReason(for agent: AgentInstance, now: Date, isStartupRecovery: Bool) -> AgentExpirationReason? {
        let paneExists: Bool? = agent.paneId.isEmpty ? nil : tmux.paneExists(agent.paneId)
        let sessionExists: Bool? = agent.sessionName.isEmpty ? nil : tmux.sessionExists(agent.sessionName)
        return AgentLivenessPolicy.expirationReason(
            for: agent,
            now: now,
            paneExists: paneExists,
            sessionExists: sessionExists,
            config: config,
            isStartupRecovery: isStartupRecovery
        )
    }

    private func expirationEvent(for agent: AgentInstance, reason: AgentExpirationReason, at now: Date) -> AgentEvent {
        Self.makeExpirationEvent(for: agent, reason: reason, at: now)
    }

    private static func makeExpirationEvent(for agent: AgentInstance, reason: AgentExpirationReason, at now: Date) -> AgentEvent {
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

    // MARK: - Snapshot / persistence

    private func currentSnapshot() -> MonitorSnapshot {
        let sortedAgents = agents.values.sorted { $0.startedAt > $1.startedAt }
        let activeAgentIDs = Set(sortedAgents.filter(\.status.isActive).map(\.id))
        let recentEvents = EventPolicy.normalizeHistory(
            Array(events.suffix(200)),
            now: nowProvider(),
            actionableWindowSeconds: config.actionableEventWindowSeconds,
            activeAgentIDs: activeAgentIDs
        )
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

    private func trimEventsIfNeeded() {
        if events.count > config.maxStoredEvents {
            events.removeFirst(events.count - config.maxStoredEvents)
        }
    }

    private func cleanupDedupeMap(now: Date) {
        let threshold = now.addingTimeInterval(-max(config.eventDedupeWindowSeconds * 12, 300))
        dedupeSeenAt = dedupeSeenAt.filter { $0.value >= threshold }
    }

    private func acknowledgeEvent(id: UUID) -> Bool {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return false }
        guard !events[index].acknowledged else { return false }
        events[index].acknowledged = true
        return true
    }

    private func acknowledgeEndedAgentEvents(agentId: UUID) -> [UUID] {
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

    private func persistEventsSnapshot() {
        trimEventsIfNeeded()
        try? eventStore.rewrite(events)
    }

    private func shouldEmitSyntheticCompletion(for agentId: UUID, now: Date) -> Bool {
        let recentWindow: TimeInterval = 30
        for event in events.reversed() {
            if event.agentId != agentId { continue }
            if now.timeIntervalSince(event.timestamp) > recentWindow {
                break
            }
            if event.eventType == .taskCompleted {
                return false
            }
        }
        return true
    }

    private func saveAgents() {
        Self.persistAgents(agents)
    }

    private func performMaintenance(_ action: MaintenanceAction) throws {
        switch action {
        case .clearLogs:
            try LocalDataMaintenance.clearLogs()

        case .clearEventHistory:
            events.removeAll()
            dedupeSeenAt.removeAll()
            try eventStore.rewrite([])

        case .clearAgentCache:
            agents.removeAll()
            stallAlertedAgentIDs.removeAll()
            saveAgents()

        case .clearAll:
            events.removeAll()
            dedupeSeenAt.removeAll()
            try eventStore.rewrite([])

            agents.removeAll()
            stallAlertedAgentIDs.removeAll()
            saveAgents()

            try LocalDataMaintenance.clearLogs()
        }
    }

    private static func persistAgents(_ agents: [UUID: AgentInstance]) {
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

    private static func hasAcknowledgementChanges(
        original: [AgentEvent],
        normalized: [AgentEvent]
    ) -> Bool {
        guard original.count == normalized.count else { return true }
        for (lhs, rhs) in zip(original, normalized) where lhs.acknowledged != rhs.acknowledged {
            return true
        }
        return false
    }
}
