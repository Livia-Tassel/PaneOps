import Foundation

public struct JumpRequest: Sendable {
    public let paneId: String
    public let windowId: String
    public let sessionName: String

    public init(paneId: String, windowId: String = "", sessionName: String = "") {
        self.paneId = paneId
        self.windowId = windowId
        self.sessionName = sessionName
    }
}

public struct JumpPreflightResult: Sendable, Equatable {
    public let canJump: Bool
    public let reason: String?

    public init(canJump: Bool, reason: String? = nil) {
        self.canJump = canJump
        self.reason = reason
    }
}

public enum JumpError: LocalizedError, Sendable {
    case tmuxUnavailable
    case paneNotFound(String)
    case sessionNotFound(String)
    case selectWindowFailed(String)
    case selectPaneFailed(String)
    case itermActivationFailed

    public var errorDescription: String? {
        switch self {
        case .tmuxUnavailable:
            return "tmux is not available on this Mac."
        case .paneNotFound(let pane):
            return "Pane \(pane) no longer exists."
        case .sessionNotFound(let session):
            return "Session '\(session)' was not found."
        case .selectWindowFailed(let window):
            return "Failed to select tmux window \(window)."
        case .selectPaneFailed(let pane):
            return "Failed to select tmux pane \(pane)."
        case .itermActivationFailed:
            return "Failed to activate iTerm2."
        }
    }
}

/// Session-aware jump helper: tmux session/window/pane selection + iTerm2 activation.
public struct JumpService: Sendable {
    private let tmux: TmuxClient
    private let runner: any CommandRunning

    public init(tmux: TmuxClient = TmuxClient(), runner: any CommandRunning = LocalCommandRunner()) {
        self.tmux = tmux
        self.runner = runner
    }

    public func preflight(_ request: JumpRequest) -> JumpPreflightResult {
        guard tmux.isAvailable() else {
            return JumpPreflightResult(canJump: false, reason: JumpError.tmuxUnavailable.localizedDescription)
        }
        guard !request.paneId.isEmpty else {
            return JumpPreflightResult(canJump: false, reason: "No tmux pane id available.")
        }
        guard tmux.paneExists(request.paneId) else {
            return JumpPreflightResult(canJump: false, reason: JumpError.paneNotFound(request.paneId).localizedDescription)
        }
        if !request.sessionName.isEmpty, !tmux.sessionExists(request.sessionName) {
            return JumpPreflightResult(canJump: false, reason: JumpError.sessionNotFound(request.sessionName).localizedDescription)
        }
        return JumpPreflightResult(canJump: true)
    }

    @discardableResult
    public func jump(to request: JumpRequest, ensureITermVisible: Bool = true) throws -> Bool {
        let check = preflight(request)
        if !check.canJump {
            if !tmux.isAvailable() { throw JumpError.tmuxUnavailable }
            if !tmux.paneExists(request.paneId) { throw JumpError.paneNotFound(request.paneId) }
            if !request.sessionName.isEmpty, !tmux.sessionExists(request.sessionName) {
                throw JumpError.sessionNotFound(request.sessionName)
            }
            throw JumpError.selectPaneFailed(request.paneId)
        }

        if !request.sessionName.isEmpty {
            guard tmux.sessionExists(request.sessionName) else {
                throw JumpError.sessionNotFound(request.sessionName)
            }
            if !tmux.switchClient(to: request.sessionName) {
                _ = attachSessionInITerm(sessionName: request.sessionName)
                _ = tmux.switchClient(to: request.sessionName)
            }
        }

        if !request.windowId.isEmpty {
            let selected = tmux.selectWindow(request.windowId, in: request.sessionName)
                || tmux.selectWindow(request.windowId)
            if !selected {
                throw JumpError.selectWindowFailed(request.windowId)
            }
        }

        guard tmux.selectPane(request.paneId) else {
            throw JumpError.selectPaneFailed(request.paneId)
        }

        if ensureITermVisible, !activateITerm() {
            throw JumpError.itermActivationFailed
        }
        return true
    }

    @discardableResult
    public func activateITerm() -> Bool {
        let result = runner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", "tell application \"iTerm2\" to activate"],
            environment: nil
        )
        return result.exitCode == 0
    }

    @discardableResult
    public func attachSessionInITerm(sessionName: String) -> Bool {
        let safeSession = sessionName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
            activate
            try
                create window with default profile command "tmux attach-session -t \(safeSession)"
            on error
                tell current window to create tab with default profile command "tmux attach-session -t \(safeSession)"
            end try
        end tell
        """
        let result = runner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            environment: nil
        )
        return result.exitCode == 0
    }
}
