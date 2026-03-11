import ArgumentParser
import SentinelShared

@main
struct SentinelCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-sentinel",
        abstract: "Monitor AI coding agents and get notified when they need attention.",
        version: SentinelVersion.current,
        subcommands: [RunCommand.self, MonitorCommand.self, ListCommand.self, JumpCommand.self],
        defaultSubcommand: RunCommand.self
    )
}
