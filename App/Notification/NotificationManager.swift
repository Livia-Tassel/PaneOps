import AppKit
import SentinelShared

/// Manages a single aggregated notification panel in the top-right corner.
final class NotificationManager: @unchecked Sendable {
    private var panel: NotificationPanel?
    private var events: [AgentEvent] = []
    private var timers: [UUID: Timer] = [:]
    private let configProvider: () -> AppConfig
    private let onAcknowledge: (UUID) -> Void
    private let horizontalInset: CGFloat = 16
    private let verticalInset: CGFloat = 16

    init(
        configProvider: @escaping () -> AppConfig,
        onAcknowledge: @escaping (UUID) -> Void = { _ in }
    ) {
        self.configProvider = configProvider
        self.onAcknowledge = onAcknowledge
    }

    /// Must be called on main thread.
    func show(event: AgentEvent) {
        assert(Thread.isMainThread, "NotificationManager.show must be called on main thread")
        guard event.shouldNotify else { return }

        upsert(event: event)
        enforceLimits()
        ensurePanel()
        refreshPanel()
        scheduleDismissTimer(for: event)
    }

    func dismiss(eventId: UUID) {
        timers[eventId]?.invalidate()
        timers.removeValue(forKey: eventId)
        events.removeAll { $0.id == eventId }
        refreshPanel()
    }

    func acknowledgeAndDismiss(eventId: UUID) {
        onAcknowledge(eventId)
        dismiss(eventId: eventId)
    }

    private func upsert(event: AgentEvent) {
        if event.eventType == .taskCompleted {
            events.insert(event, at: 0)
            return
        }

        if let index = events.firstIndex(where: { $0.dedupeKey == event.dedupeKey }) {
            let oldId = events[index].id
            if oldId != event.id {
                timers[oldId]?.invalidate()
                timers.removeValue(forKey: oldId)
            }
            events[index] = event
        } else {
            events.insert(event, at: 0)
        }
    }

    private func enforceLimits() {
        let maxVisible = max(1, configProvider().maxNotifications)
        if events.count > maxVisible {
            let toDrop = events.suffix(events.count - maxVisible)
            for item in toDrop {
                timers[item.id]?.invalidate()
                timers.removeValue(forKey: item.id)
            }
            events = Array(events.prefix(maxVisible))
        }
    }

    private func scheduleDismissTimer(for event: AgentEvent) {
        timers[event.id]?.invalidate()
        if event.eventType.requiresManualDismissInOverlay {
            timers.removeValue(forKey: event.id)
            return
        }
        let config = configProvider()
        let configured = event.priority == .high ? config.highDismissSeconds : config.normalDismissSeconds
        let timeout = max(configured, event.eventType.autoDismissSeconds)
        let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismiss(eventId: event.id)
            }
        }
        timers[event.id] = timer
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        panel = NotificationPanel(
            onDismiss: { [weak self] eventId in
                DispatchQueue.main.async {
                    self?.acknowledgeAndDismiss(eventId: eventId)
                }
            },
            onJump: { [weak self] event in
                DispatchQueue.main.async {
                    JumpController.jumpToPane(
                        paneId: event.paneId,
                        windowId: event.windowId,
                        sessionName: event.sessionName
                    )
                    self?.acknowledgeAndDismiss(eventId: event.id)
                }
            }
        )
        panel?.alphaValue = 0
    }

    private func refreshPanel() {
        guard let panel else { return }
        if events.isEmpty {
            panel.dismissAnimated { [weak self] in
                self?.panel = nil
            }
            return
        }

        panel.update(events: events)
        position(panel: panel, for: events.count)
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func position(panel: NotificationPanel, for eventCount: Int) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let width = panel.frame.width
        let height = panel.preferredHeight(for: eventCount)
        let x = visible.maxX - width - horizontalInset
        let y = visible.maxY - height - verticalInset
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}
