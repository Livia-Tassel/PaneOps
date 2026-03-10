import AppKit
import SentinelShared

/// Manages a single aggregated notification panel in the top-right corner.
final class NotificationManager: @unchecked Sendable {
    private var panel: NotificationPanel?
    private var events: [AgentEvent] = []
    private var timers: [UUID: Timer] = [:]
    private let configProvider: () -> AppConfig
    private let horizontalInset: CGFloat = 16
    private let verticalInset: CGFloat = 16

    init(configProvider: @escaping () -> AppConfig) {
        self.configProvider = configProvider
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

    private func upsert(event: AgentEvent) {
        if let index = events.firstIndex(where: { $0.dedupeKey == event.dedupeKey }) {
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
        let config = configProvider()
        let timeout = event.priority == .high ? config.highDismissSeconds : config.normalDismissSeconds
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
                    self?.dismiss(eventId: eventId)
                }
            },
            onJump: { [weak self] event in
                DispatchQueue.main.async {
                    JumpController.jumpToPane(
                        paneId: event.paneId,
                        windowId: event.windowId,
                        sessionName: event.sessionName
                    )
                    self?.dismiss(eventId: event.id)
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
