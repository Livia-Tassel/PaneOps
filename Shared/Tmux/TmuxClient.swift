import Foundation

/// Client for interacting with tmux via shell commands.
public struct TmuxClient: Sendable {
    private let runner: any CommandRunning
    private let tmuxExecutable: String

    private static let paneFormat = "#{pane_id}\t#{window_id}\t#{session_name}\t#{session_id}\t#{window_name}\t#{pane_title}\t#{pane_pid}\t#{pane_current_path}\t#{pane_active}"
    private static let preferredExecutables = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    public init(runner: any CommandRunning = LocalCommandRunner(), tmuxExecutable: String? = nil) {
        self.runner = runner
        self.tmuxExecutable = tmuxExecutable ?? Self.resolveTmuxExecutable(runner: runner)
    }

    static func resolveTmuxExecutable(
        runner: any CommandRunning = LocalCommandRunner(),
        executableChecker: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        for candidate in preferredExecutables where executableChecker(candidate) {
            return candidate
        }

        let which = runner.run(executable: "/usr/bin/which", arguments: ["tmux"], environment: nil)
        if which.exitCode == 0 {
            let path = which.stdout
                .split(separator: "\n")
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            if !path.isEmpty, executableChecker(path) {
                return path
            }
        }

        // Last resort when path lookup is unavailable.
        return "/usr/bin/env"
    }

    /// Check if tmux is available.
    public func isAvailable() -> Bool {
        let result = runTmux(["-V"])
        return result.exitCode == 0
    }

    /// Get current pane info (from inside a tmux session).
    public func currentPane() -> PaneInfo? {
        let result = runTmux(["display-message", "-p", Self.paneFormat])
        guard result.exitCode == 0 else { return nil }
        return parsePaneLine(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Get pane info for a specific pane id.
    public func paneInfo(for paneId: String) -> PaneInfo? {
        guard !paneId.isEmpty else { return nil }
        let result = runTmux(["display-message", "-p", "-t", paneId, Self.paneFormat])
        guard result.exitCode == 0 else { return nil }
        return parsePaneLine(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// List all panes across all sessions.
    public func listPanes() -> [PaneInfo] {
        let result = runTmux(["list-panes", "-a", "-F", Self.paneFormat])
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
        let parts = line.split(separator: "\t", maxSplits: 8, omittingEmptySubsequences: false)
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
        let executable: String
        let invocation: [String]
        if tmuxExecutable == "/usr/bin/env" {
            executable = "/usr/bin/env"
            invocation = ["tmux"] + arguments
        } else {
            executable = tmuxExecutable
            invocation = arguments
        }

        let result = runner.run(executable: executable, arguments: invocation, environment: nil)
        if result.exitCode != 0 {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !err.isEmpty {
                let command = (tmuxExecutable == "/usr/bin/env" ? ["tmux"] : [tmuxExecutable]) + arguments
                SentinelLogger.tmux.warning("\(command.joined(separator: " ")) failed: \(err)")
            }
        }
        return result
    }
}
