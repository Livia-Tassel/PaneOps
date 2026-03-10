import Foundation

/// Information about a tmux pane.
public struct PaneInfo: Sendable {
    public let paneId: String       // %N
    public let windowId: String     // @N
    public let sessionName: String
    public let sessionId: String
    public let windowName: String
    public let paneTitle: String
    public let panePid: String
    public let paneCurrentPath: String
    public let paneActive: Bool

    public init(paneId: String, windowId: String, sessionName: String, sessionId: String,
                windowName: String, paneTitle: String, panePid: String, paneCurrentPath: String,
                paneActive: Bool) {
        self.paneId = paneId
        self.windowId = windowId
        self.sessionName = sessionName
        self.sessionId = sessionId
        self.windowName = windowName
        self.paneTitle = paneTitle
        self.panePid = panePid
        self.paneCurrentPath = paneCurrentPath
        self.paneActive = paneActive
    }
}

/// Information about a tmux session.
public struct SessionInfo: Sendable {
    public let sessionId: String
    public let sessionName: String
    public let windowCount: Int
    public let attached: Bool

    public init(sessionId: String, sessionName: String, windowCount: Int, attached: Bool) {
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.windowCount = windowCount
        self.attached = attached
    }
}
