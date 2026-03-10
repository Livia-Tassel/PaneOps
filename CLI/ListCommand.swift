import ArgumentParser
import Foundation
import SentinelShared

/// `agent-sentinel list` — show active agents.
struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List active monitored agents."
    )

    func run() throws {
        let agentsFile = AppConfig.agentsFile
        guard FileManager.default.fileExists(atPath: agentsFile.path) else {
            print("No active agents.")
            return
        }

        let data = try Data(contentsOf: agentsFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let agents = try decoder.decode([AgentInstance].self, from: data)

        guard !agents.isEmpty else {
            print("No active agents.")
            return
        }

        // Table header
        let format = "%-8s  %-8s  %-20s  %-10s  %-8s  %s"
        let header = String(format: format, "PANE", "TYPE", "LABEL", "STATUS", "PID",  "STARTED")
        print(header)
        print(String(repeating: "─", count: 80))

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        for agent in agents {
            let line = String(
                format: format,
                (agent.paneId as NSString).utf8String!,
                (agent.agentType.displayName as NSString).utf8String!,
                (agent.displayLabel as NSString).utf8String!,
                (agent.status.rawValue as NSString).utf8String!,
                (String(agent.pid) as NSString).utf8String!,
                (dateFormatter.string(from: agent.startedAt) as NSString).utf8String!
            )
            print(line)
        }
    }
}
