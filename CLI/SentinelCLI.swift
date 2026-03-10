import ArgumentParser

@main
struct SentinelCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-sentinel",
        abstract: "Monitor AI coding agents and get notified when they need attention.",
        version: "0.1.0",
        subcommands: [RunCommand.self, MonitorCommand.self, ListCommand.self, JumpCommand.self],
        defaultSubcommand: RunCommand.self
    )
}
