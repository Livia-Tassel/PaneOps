import Foundation
import SentinelShared

actor MonitorState {
    private var config: AppConfig
    private var agents: [UUID: AgentInstance]
    private var events: [AgentEvent]
    private var deduplicator = EventDeduplicator()
    private var paneSupersededAgentIDs: Set<UUID> = []
    private var subscribers: [UUID: IPCServer.ClientConnection] = [:]

    private let tmux: TmuxClient
    private let nowProvider: @Sendable () -> Date
    private let eventStore: EventStore
    private let persistAgentsHandler: ([UUID: AgentInstance]) -> Void

    init(
        tmux: TmuxClient = TmuxClient(),
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        config: AppConfig? = nil,
        eventStore: EventStore? = nil,
        initialAgents: [UUID: AgentInstance]? = nil,
        initialEvents: [AgentEvent]? = nil,
        persistAgents: (([UUID: AgentInstance]) -> Void)? = nil
    ) {
        let resolvedConfig = (config ?? AppConfig.load()).normalized()
        let resolvedEventStore = eventStore ?? EventStore(fileURL: AppConfig.eventsFile, maxLines: resolvedConfig.maxStoredEvents)

        self.tmux = tmux
        self.nowProvider = nowProvider
        self.config = resolvedConfig
        self.eventStore = resolvedEventStore
        self.agents = initialAgents ?? MonitorState.loadAgents()
        self.persistAgentsHandler = persistAgents ?? MonitorState.persistAgents

        let now = nowProvider()
        let loadedEvents = initialEvents ?? resolvedEventStore.loadRecent(resolvedConfig.maxStoredEvents)
        let startupActiveAgentIDs = Set(self.agents.values.filter(\.status.isActive).map(\.id))
        self.events = EventPolicy.normalizeHistory(
            loadedEvents,
            now: now,
            actionableWindowSeconds: resolvedConfig.actionableEventWindowSeconds,
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

            let event = PaneCollapsePolicy.makeExpirationEvent(for: agent, reason: reason, at: now)
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
            persistAgentsHandler(agents)
            try? resolvedEventStore.rewrite(self.events)
        }
    }

    func handle(_ message: IPCMessage, from connection: IPCServer.ClientConnection) async {
        switch message {
        case .subscribe:
            subscribers[connection.id] = connection
            do {
                try connection.send(.snapshot(currentSnapshot()))
            } catch {
                subscribers.removeValue(forKey: connection.id)
                SentinelLogger.ipc.warning("Failed to send snapshot: \(error.localizedDescription)")
            }

        case .register(let agent):
            let now = nowProvider()
            var updated = agent
            updated.lastActiveAt = now
            updated.status = .running

            let collapsed = collapseActiveAgentsSharingPane(with: updated, now: now)
            agents[agent.id] = updated
            deduplicator.clearStallAlert(for: agent.id)
            paneSupersededAgentIDs.remove(agent.id)
            trimEventsIfNeeded()
            saveAgents()

            if !collapsed.generatedEvents.isEmpty || !collapsed.ackedEventIDs.isEmpty {
                persistEventsSnapshot()
            }
            for event in collapsed.generatedEvents {
                await broadcast(.event(event))
            }
            for eventId in collapsed.ackedEventIDs {
                await broadcast(.ack(messageId: eventId))
            }
            await broadcast(.register(updated))

        case .heartbeat(let agentId):
            guard var agent = agents[agentId] else { break }
            guard !paneSupersededAgentIDs.contains(agentId) else { break }

            agent.recordHeartbeat(at: nowProvider())
            agents[agentId] = agent
            saveAgents()
            await broadcast(.heartbeat(agentId: agentId))

        case .activity(let agentId):
            guard var agent = agents[agentId] else { break }
            guard !paneSupersededAgentIDs.contains(agentId) else { break }

            let previousStatus = agent.status
            agent.recordOutputActivity(at: nowProvider())
            agents[agentId] = agent

            guard previousStatus != agent.status else { break }

            deduplicator.clearStallAlert(for: agentId)
            let ackedIds = AcknowledgmentPolicy.acknowledgeRecovered(
                agentId: agentId,
                eventTypes: [.stalledOrWaiting],
                in: &events
            )
            saveAgents()
            if !ackedIds.isEmpty {
                persistEventsSnapshot()
            }
            await broadcast(.activity(agentId: agentId))
            for eventId in ackedIds {
                await broadcast(.ack(messageId: eventId))
            }

        case .resume(let agentId):
            guard var agent = agents[agentId] else { break }
            guard !paneSupersededAgentIDs.contains(agentId) else { break }
            guard agent.status == .waiting || agent.status == .stalled || agent.status == .expired else { break }

            agent.recordResume(at: nowProvider())
            agents[agentId] = agent
            deduplicator.clearStallAlert(for: agentId)

            let ackedIds = AcknowledgmentPolicy.acknowledgeRecovered(
                agentId: agentId,
                eventTypes: [.stalledOrWaiting, .inputRequested, .permissionRequested],
                in: &events
            )
            saveAgents()
            if !ackedIds.isEmpty {
                persistEventsSnapshot()
            }
            await broadcast(.resume(agentId: agentId))
            for eventId in ackedIds {
                await broadcast(.ack(messageId: eventId))
            }

        case .event(let event):
            guard !paneSupersededAgentIDs.contains(event.agentId) else { return }
            guard deduplicator.shouldAccept(event: event, config: config, now: nowProvider()) else { return }

            var accepted = event
            if accepted.eventType == .taskCompleted || !accepted.shouldNotify {
                accepted.acknowledged = true
            }
            deduplicator.updateStallAlertGate(for: accepted)

            apply(event: accepted)
            events.append(accepted)
            trimEventsIfNeeded()

            try? eventStore.append(accepted)
            await broadcast(.event(accepted))

        case .deregister(let agentId, let exitCode):
            let now = nowProvider()
            if exitCode == 0,
               !paneSupersededAgentIDs.contains(agentId),
               shouldEmitSyntheticCompletion(for: agentId, now: now),
               let agent = agents[agentId]
            {
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

                if deduplicator.shouldAccept(event: completionEvent, config: config, now: now) {
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
            deduplicator.clearStallAlert(for: agentId)
            paneSupersededAgentIDs.remove(agentId)
            let ackedIds = AcknowledgmentPolicy.acknowledgeEndedAgent(agentId, in: &events)
            saveAgents()
            if !ackedIds.isEmpty {
                persistEventsSnapshot()
                for eventId in ackedIds {
                    await broadcast(.ack(messageId: eventId))
                }
            }
            await broadcast(.deregister(agentId: agentId, exitCode: exitCode))

        case .configUpdate(let newConfig):
            config = newConfig.normalized()
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
            if AcknowledgmentPolicy.acknowledge(eventId: messageId, in: &events) {
                persistEventsSnapshot()
                await broadcast(.ack(messageId: messageId))
            }

        case .sendKeys(let request):
            let success = tmux.sendKeys(to: request.paneId, text: request.text, enterAfter: request.enterAfter)
            if !success {
                SentinelLogger.tmux.warning("sendKeys failed for pane \(request.paneId)")
            }

        case .snapshot:
            break
        }
    }

    func clientDisconnected(_ connection: IPCServer.ClientConnection) {
        subscribers.removeValue(forKey: connection.id)
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
            if deduplicator.shouldAccept(event: event, config: config, now: now) {
                events.append(event)
                generated.append(event)
                try? eventStore.append(event)
            }
            ackedIds.append(contentsOf: AcknowledgmentPolicy.acknowledgeEndedAgent(agent.id, in: &events))
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

        deduplicator.cleanup(now: now, dedupeWindowSeconds: config.eventDedupeWindowSeconds)
    }

    // MARK: - Event semantics

    private func collapseActiveAgentsSharingPane(with incoming: AgentInstance, now: Date) -> (generatedEvents: [AgentEvent], ackedEventIDs: [UUID]) {
        let candidates = PaneCollapsePolicy.agentsToCollapse(incoming: incoming, agents: agents)
        guard !candidates.isEmpty else { return ([], []) }

        var generatedEvents: [AgentEvent] = []
        var ackedEventIDs: [UUID] = []

        for candidate in candidates {
            agents[candidate.id]?.status = .expired
            agents[candidate.id]?.lastActiveAt = now
            deduplicator.clearStallAlert(for: candidate.id)
            paneSupersededAgentIDs.insert(candidate.id)

            var replacementEvent = PaneCollapsePolicy.makePaneReplacementEvent(for: candidate, replacement: incoming, at: now)
            if deduplicator.shouldAccept(event: replacementEvent, config: config, now: now) {
                replacementEvent.acknowledged = true
                events.append(replacementEvent)
                generatedEvents.append(replacementEvent)
                try? eventStore.append(replacementEvent)
            }
            ackedEventIDs.append(contentsOf: AcknowledgmentPolicy.acknowledgeEndedAgent(candidate.id, in: &events))
        }

        return (generatedEvents, ackedEventIDs)
    }

    private func apply(event: AgentEvent) {
        guard var agent = agents[event.agentId] else { return }
        agent.apply(event: event)
        agents[event.agentId] = agent
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
        PaneCollapsePolicy.makeExpirationEvent(for: agent, reason: reason, at: now)
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
        var dead: [UUID] = []
        for (subscriberId, conn) in subscribers {
            do {
                try conn.send(message)
            } catch {
                dead.append(subscriberId)
            }
        }
        for subscriberId in dead {
            subscribers.removeValue(forKey: subscriberId)
        }
    }

    private func trimEventsIfNeeded() {
        let maxStoredEvents = max(config.maxStoredEvents, 1)
        if events.count > maxStoredEvents {
            events.removeFirst(events.count - maxStoredEvents)
        }
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
        persistAgentsHandler(agents)
    }

    private func performMaintenance(_ action: MaintenanceAction) throws {
        switch action {
        case .clearLogs:
            try LocalDataMaintenance.clearLogs()

        case .clearEventHistory:
            events.removeAll()
            deduplicator.clearAll()
            try eventStore.rewrite([])

        case .clearAgentCache:
            agents.removeAll()
            deduplicator.clearAll()
            saveAgents()

        case .clearAll:
            events.removeAll()
            deduplicator.clearAll()
            try eventStore.rewrite([])

            agents.removeAll()
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
