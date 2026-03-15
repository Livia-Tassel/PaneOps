import AppKit
import SwiftUI
import SentinelShared

final class AppDelegate: NSObject, NSApplicationDelegate {
    let agentRegistry = AgentRegistry()
    let ipcService = IPCService()
    private var notificationManager: NotificationManager?
    private let completionReplayWindowSeconds: TimeInterval = 30
    private let shownNotificationRetentionSeconds: TimeInterval = 6 * 60 * 60
    private var shownNotificationEvents: [UUID: Date] = [:]
    private var hasReceivedInitialSnapshot = false
    private var shouldReplayCompletionsOnNextSnapshot = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? AppConfig.ensureDirectory()
        MonitorBootstrap.ensureRunning()

        notificationManager = NotificationManager(
            configProvider: { [weak self] in
                self?.agentRegistry.config ?? AppConfig()
            },
            onAcknowledge: { [weak self] eventId in
                guard let self else { return }
                self.agentRegistry.acknowledgeEvent(id: eventId)
                self.ipcService.send(.ack(messageId: eventId))
            }
        )

        ipcService.onConnectionChanged = { [weak self] connected in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasConnected = self.agentRegistry.monitorConnected
                self.agentRegistry.monitorConnected = connected
                if connected, !wasConnected, self.hasReceivedInitialSnapshot {
                    self.shouldReplayCompletionsOnNextSnapshot = true
                }
            }
        }

        ipcService.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }

        ipcService.start()
        SentinelLogger.ui.info("Agent Sentinel app started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipcService.stop()
    }

    private func handleMessage(_ message: IPCMessage) {
        switch message {
        case .snapshot(let snapshot):
            agentRegistry.applySnapshot(snapshot)
            if shouldReplayCompletionsOnNextSnapshot {
                replayRecentCompletionNotifications(from: snapshot.events)
                shouldReplayCompletionsOnNextSnapshot = false
            }
            hasReceivedInitialSnapshot = true
            syncOverlayFromRegistry()

        case .register(let agent):
            agentRegistry.register(agent)

        case .event(let event):
            agentRegistry.addEvent(event)
            agentRegistry.updateStatus(agentId: event.agentId, event: event)
            showNotificationIfNeeded(event)

        case .deregister(let agentId, let exitCode):
            let status: AgentStatus = (exitCode == 0) ? .completed : .errored
            agentRegistry.deregister(agentId: agentId, status: status)

        case .heartbeat(let agentId):
            agentRegistry.heartbeat(agentId: agentId)

        case .activity(let agentId):
            agentRegistry.activity(agentId: agentId)

        case .resume(let agentId):
            agentRegistry.resume(agentId: agentId)

        case .configUpdate(let config):
            agentRegistry.config = config
            syncOverlayFromRegistry()

        case .ack(let messageId):
            agentRegistry.acknowledgeEvent(id: messageId)
            notificationManager?.dismiss(eventId: messageId)

        case .maintenance:
            break

        case .subscribe:
            break

        case .sendKeys:
            break // App never receives this; Monitor-only
        }
    }

    private func syncOverlayFromRegistry() {
        guard let notificationManager else { return }
        guard agentRegistry.config.notificationsEnabled else {
            notificationManager.replaceVisibleEvents(with: [])
            return
        }

        let overlayEvents = agentRegistry.recentEvents.filter { event in
            guard event.shouldNotify else { return false }
            return EventPolicy.isActionable(
                event,
                now: Date(),
                actionableWindowSeconds: agentRegistry.config.actionableEventWindowSeconds,
                activeAgentIDs: agentRegistry.activeAgentIDs
            )
        }
        notificationManager.replaceVisibleEvents(with: overlayEvents)
    }

    private func replayRecentCompletionNotifications(from events: [AgentEvent]) {
        guard agentRegistry.config.notificationsEnabled else { return }
        let replayable = NotificationReplayPolicy.replayableCompletionEvents(
            from: events,
            now: Date(),
            replayWindowSeconds: completionReplayWindowSeconds,
            alreadyShownEventIDs: Set(shownNotificationEvents.keys)
        )
        for event in replayable {
            showNotificationIfNeeded(event)
        }
    }

    private func showNotificationIfNeeded(_ event: AgentEvent) {
        guard agentRegistry.config.notificationsEnabled else { return }
        guard event.shouldNotify else { return }
        guard shownNotificationEvents[event.id] == nil else { return }
        shownNotificationEvents[event.id] = Date()
        trimShownNotificationHistory(reference: Date())
        notificationManager?.show(event: event)
    }

    private func trimShownNotificationHistory(reference now: Date) {
        let threshold = now.addingTimeInterval(-shownNotificationRetentionSeconds)
        shownNotificationEvents = shownNotificationEvents.filter { $0.value >= threshold }
    }
}
