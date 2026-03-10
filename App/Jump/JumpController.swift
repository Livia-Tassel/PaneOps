import AppKit
import Foundation
import SentinelShared

/// Controller for jumping to a tmux pane and activating iTerm2.
@MainActor
enum JumpController {
    /// Jump to a specific agent's pane.
    static func jump(to agent: AgentInstance) {
        jumpToPane(
            paneId: agent.paneId,
            windowId: agent.windowId,
            sessionName: agent.sessionName
        )
    }

    /// Jump to a pane by ID.
    static func jumpToPane(paneId: String, windowId: String = "", sessionName: String = "") {
        guard !paneId.isEmpty else { return }

        do {
            try JumpService().jump(
                to: JumpRequest(
                    paneId: paneId,
                    windowId: windowId,
                    sessionName: sessionName
                )
            )
        } catch {
            SentinelLogger.ui.warning("Jump failed for pane \(paneId): \(error.localizedDescription)")
            showAlert(
                title: "Jump Failed",
                message: error.localizedDescription
            )
        }
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
