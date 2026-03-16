import AppKit
import SwiftUI
import SentinelShared

/// A single floating panel that aggregates multiple notification events.
/// Supports keyboard navigation: ↑/↓ to select, Enter to jump, Y/N for permission, Esc to dismiss.
final class NotificationPanel: NSPanel {
    private let onDismiss: (UUID) -> Void
    private let onJump: (AgentEvent) -> Void
    private let onSendKeys: (String, String, Bool) -> Void
    private let hostingView: NSHostingView<NotificationCardView>
    private var currentEvents: [AgentEvent] = []
    private var selectedIndex: Int = 0

    init(
        onDismiss: @escaping (UUID) -> Void,
        onJump: @escaping (AgentEvent) -> Void,
        onSendKeys: @escaping (String, String, Bool) -> Void = { _, _, _ in }
    ) {
        self.onDismiss = onDismiss
        self.onJump = onJump
        self.onSendKeys = onSendKeys
        self.hostingView = NSHostingView(
            rootView: NotificationCardView(
                events: [],
                onDismiss: onDismiss,
                onJump: onJump,
                onSendKeys: onSendKeys
            )
        )

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        hostingView.frame = NSRect(x: 0, y: 0, width: 380, height: 120)
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView
    }

    /// Allow the panel to accept keyboard input for the reply TextField
    /// without stealing app activation from iTerm2 or other apps.
    override var canBecomeKey: Bool { true }

    func update(events: [AgentEvent]) {
        currentEvents = events
        if selectedIndex >= events.count {
            selectedIndex = max(0, events.count - 1)
        }
        hostingView.rootView = NotificationCardView(
            events: events,
            onDismiss: onDismiss,
            onJump: onJump,
            onSendKeys: onSendKeys
        )
        let height = preferredHeight(for: events)
        setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: 380, height: height), display: true)
    }

    func preferredHeight(for events: [AgentEvent]) -> CGFloat {
        let baseRowHeight: CGFloat = 76
        let headerHeight: CGFloat = 36
        let verticalPadding: CGFloat = 16

        // Add extra height for rows with context lines or action buttons
        var totalRowHeight: CGFloat = 0
        for event in events {
            var rowHeight = baseRowHeight
            if let ctx = event.contextLines, !ctx.isEmpty {
                rowHeight += CGFloat(min(ctx.count, 5)) * 14 + 16
            }
            if event.eventType == .permissionRequested, !event.paneId.isEmpty {
                rowHeight += 24
            }
            if (event.eventType == .taskCompleted || event.eventType == .inputRequested),
               !event.paneId.isEmpty {
                rowHeight += 30
            }
            totalRowHeight += rowHeight
        }

        if events.isEmpty {
            totalRowHeight = baseRowHeight
        }

        return min(600, headerHeight + verticalPadding + totalRowHeight)
    }

    /// Legacy overload for callers that pass just the count.
    func preferredHeight(for eventCount: Int) -> CGFloat {
        let rowHeight: CGFloat = 76
        let headerHeight: CGFloat = 36
        let verticalPadding: CGFloat = 16
        return min(460, headerHeight + verticalPadding + CGFloat(max(1, eventCount)) * rowHeight)
    }

    // MARK: - Keyboard navigation

    override func keyDown(with event: NSEvent) {
        guard !currentEvents.isEmpty else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 126: // Up arrow
            selectedIndex = max(0, selectedIndex - 1)
            jumpToSelectedEvent()
        case 125: // Down arrow
            selectedIndex = min(currentEvents.count - 1, selectedIndex + 1)
            jumpToSelectedEvent()
        case 36: // Enter — jump to selected event's pane
            jumpToSelectedEvent()
        case 53: // Escape — dismiss selected event
            let selected = currentEvents[selectedIndex]
            onDismiss(selected.id)
        default:
            if let chars = event.characters?.lowercased() {
                let selected = currentEvents[selectedIndex]
                if chars == "y", selected.eventType == .permissionRequested, !selected.paneId.isEmpty {
                    onSendKeys(selected.paneId, "y", true)
                    onDismiss(selected.id)
                } else if chars == "n", selected.eventType == .permissionRequested, !selected.paneId.isEmpty {
                    onSendKeys(selected.paneId, "n", true)
                    onDismiss(selected.id)
                } else if chars == "j" {
                    jumpToSelectedEvent()
                } else {
                    super.keyDown(with: event)
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func jumpToSelectedEvent() {
        guard selectedIndex < currentEvents.count else { return }
        let selected = currentEvents[selectedIndex]
        onJump(selected)
    }

    func dismissAnimated(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
            completion?()
        })
    }
}
