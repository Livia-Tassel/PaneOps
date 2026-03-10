import ArgumentParser
import Foundation
import SentinelShared

/// `agent-sentinel jump` — jump to an agent's pane.
struct JumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jump",
        abstract: "Jump to an agent's tmux pane."
    )

    @Argument(help: "Pane ID (%%N) or agent label to jump to.")
    var target: String

    func run() throws {
        let tmux = TmuxClient()
        let jumpService = JumpService(tmux: tmux)

        // First, try as a literal pane ID
        if target.hasPrefix("%") && tmux.paneExists(target) {
            try jumpService.jump(to: JumpRequest(paneId: target))
            print("Jumped to pane \(target)")
            return
        }

        // Otherwise, look up by label in agents file
        let agentsFile = AppConfig.agentsFile
        guard FileManager.default.fileExists(atPath: agentsFile.path) else {
            throw ValidationError("No active agents found. Is the sentinel app running?")
        }

        let data = try Data(contentsOf: agentsFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let agents = try decoder.decode([AgentInstance].self, from: data)

        // Match by label (case-insensitive) or pane ID
        let matches = agents.filter {
            $0.displayLabel.localizedCaseInsensitiveCompare(target) == .orderedSame ||
            $0.paneId == target
        }
        guard !matches.isEmpty else {
            throw ValidationError("No agent found matching '\(target)'")
        }
        if matches.count > 1 {
            let panes = matches.map(\.paneId).joined(separator: ", ")
            throw ValidationError("Multiple agents match '\(target)'. Use pane id directly: \(panes)")
        }
        guard let agent = matches.first else {
            throw ValidationError("No agent found matching '\(target)'")
        }

        guard tmux.paneExists(agent.paneId) else {
            throw ValidationError("Pane \(agent.paneId) no longer exists")
        }

        do {
            try jumpService.jump(
                to: JumpRequest(
                    paneId: agent.paneId,
                    windowId: agent.windowId,
                    sessionName: agent.sessionName
                )
            )
        } catch {
            throw ValidationError(error.localizedDescription)
        }
        print("Jumped to pane \(agent.paneId)")
    }
}
