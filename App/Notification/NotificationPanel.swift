import AppKit
import SwiftUI
import SentinelShared

/// A single floating panel that aggregates multiple notification events.
final class NotificationPanel: NSPanel {
    private let onDismiss: (UUID) -> Void
    private let onJump: (AgentEvent) -> Void
    private let hostingView: NSHostingView<NotificationCardView>

    init(onDismiss: @escaping (UUID) -> Void, onJump: @escaping (AgentEvent) -> Void) {
        self.onDismiss = onDismiss
        self.onJump = onJump
        self.hostingView = NSHostingView(
            rootView: NotificationCardView(
                events: [],
                onDismiss: onDismiss,
                onJump: onJump
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

    func update(events: [AgentEvent]) {
        hostingView.rootView = NotificationCardView(
            events: events,
            onDismiss: onDismiss,
            onJump: onJump
        )
        let height = preferredHeight(for: events.count)
        setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: 380, height: height), display: true)
    }

    func preferredHeight(for eventCount: Int) -> CGFloat {
        let count = max(1, eventCount)
        let rowHeight: CGFloat = 76
        let headerHeight: CGFloat = 36
        let verticalPadding: CGFloat = 16
        return min(460, headerHeight + verticalPadding + CGFloat(count) * rowHeight)
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
