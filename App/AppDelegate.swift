import AppKit
import SwiftUI
import SentinelShared

final class AppDelegate: NSObject, NSApplicationDelegate {
    let agentRegistry = AgentRegistry()
    let ipcService = IPCService()
    private var notificationManager: NotificationManager?

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
                self?.agentRegistry.monitorConnected = connected
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
            syncOverlayFromRegistry()

        case .register(let agent):
            agentRegistry.register(agent)

        case .event(let event):
            agentRegistry.addEvent(event)
            agentRegistry.updateStatus(agentId: event.agentId, event: event)
            if agentRegistry.config.notificationsEnabled && event.shouldNotify {
                notificationManager?.show(event: event)
            }

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
}
