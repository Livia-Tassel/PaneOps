import Foundation

/// Client for interacting with tmux via shell commands.
public struct TmuxClient: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = LocalCommandRunner()) {
        self.runner = runner
    }

    /// Check if tmux is available.
    public func isAvailable() -> Bool {
        let result = runTmux(["-V"])
        return result.exitCode == 0
    }

    /// Get current pane info (from inside a tmux session).
    public func currentPane() -> PaneInfo? {
        let format = "#{pane_id}\t#{window_id}\t#{session_name}\t#{session_id}\t#{window_name}\t#{pane_title}\t#{pane_pid}\t#{pane_current_path}\t#{pane_active}"
        let result = runTmux(["display-message", "-p", format])
        guard result.exitCode == 0 else { return nil }
        return parsePaneLine(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// List all panes across all sessions.
    public func listPanes() -> [PaneInfo] {
        let format = "#{pane_id}\t#{window_id}\t#{session_name}\t#{session_id}\t#{window_name}\t#{pane_title}\t#{pane_pid}\t#{pane_current_path}\t#{pane_active}"
        let result = runTmux(["list-panes", "-a", "-F", format])
        guard result.exitCode == 0 else { return [] }
        return result.stdout
            .split(separator: "\n")
            .compactMap { parsePaneLine(String($0)) }
    }

    /// Verify a pane exists.
    public func paneExists(_ paneId: String) -> Bool {
        let result = runTmux(["display-message", "-t", paneId, "-p", "#{pane_id}"])
        return result.exitCode == 0
    }

    /// Switch active client to a target session.
    public func switchClient(to sessionName: String) -> Bool {
        guard !sessionName.isEmpty else { return false }
        return runTmux(["switch-client", "-t", sessionName]).exitCode == 0
    }

    /// Check whether a session currently has an attached client.
    public func hasAttachedClient(in sessionName: String) -> Bool {
        guard !sessionName.isEmpty else { return false }
        let result = runTmux(["list-clients", "-t", sessionName])
        return result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Select a window by ID.
    public func selectWindow(_ windowId: String, in sessionName: String? = nil) -> Bool {
        guard !windowId.isEmpty else { return false }
        var target = windowId
        if let sessionName, !sessionName.isEmpty, !windowId.contains(":") {
            target = "\(sessionName):\(windowId)"
        }
        return runTmux(["select-window", "-t", target]).exitCode == 0
    }

    /// Select a pane by ID.
    public func selectPane(_ paneId: String) -> Bool {
        runTmux(["select-pane", "-t", paneId]).exitCode == 0
    }

    /// Ensure a given session exists.
    public func sessionExists(_ sessionName: String) -> Bool {
        guard !sessionName.isEmpty else { return false }
        return runTmux(["has-session", "-t", sessionName]).exitCode == 0
    }

    /// List sessions.
    public func listSessions() -> [SessionInfo] {
        let format = "#{session_id}\t#{session_name}\t#{session_windows}\t#{session_attached}"
        let result = runTmux(["list-sessions", "-F", format])
        guard result.exitCode == 0 else { return [] }
        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> SessionInfo? in
                let parts = line.split(separator: "\t", maxSplits: 3)
                guard parts.count == 4 else { return nil }
                return SessionInfo(
                    sessionId: String(parts[0]),
                    sessionName: String(parts[1]),
                    windowCount: Int(parts[2]) ?? 0,
                    attached: parts[3] == "1"
                )
            }
    }

    // MARK: - Private

    private func parsePaneLine(_ line: String) -> PaneInfo? {
        let parts = line.split(separator: "\t", maxSplits: 8)
        guard parts.count == 9 else { return nil }
        return PaneInfo(
            paneId: String(parts[0]),
            windowId: String(parts[1]),
            sessionName: String(parts[2]),
            sessionId: String(parts[3]),
            windowName: String(parts[4]),
            paneTitle: String(parts[5]),
            panePid: String(parts[6]),
            paneCurrentPath: String(parts[7]),
            paneActive: parts[8] == "1"
        )
    }

    private func runTmux(_ arguments: [String]) -> CommandResult {
        let result = runner.run(executable: "/usr/bin/env", arguments: ["tmux"] + arguments, environment: nil)
        if result.exitCode != 0 {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !err.isEmpty {
                SentinelLogger.tmux.warning("tmux \(arguments.joined(separator: " ")) failed: \(err)")
            }
        }
        return result
    }
}
