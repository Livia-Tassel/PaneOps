import ArgumentParser
import Foundation
import SentinelShared

/// `agent-sentinel _monitor` — internal subcommand run inside a tmux pane.
/// Not intended for direct user invocation.
struct MonitorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_monitor",
        abstract: "Internal: monitor an agent process (not for direct use).",
        shouldDisplay: false
    )

    @Option(name: .long, help: "Agent ID (UUID)")
    var agentId: String

    @Option(name: .long, help: "Agent type")
    var agentType: String

    @Option(name: .long, help: "Display label")
    var label: String = ""

    @Option(name: .long, help: "Pane ID")
    var paneId: String = ""

    @Option(name: .long, help: "Window ID")
    var windowId: String = ""

    @Option(name: .long, help: "Session name")
    var sessionName: String = ""

    @Argument(parsing: .captureForPassthrough, help: "Command to monitor")
    var command: [String]

    func run() throws {
        let normalizedCommand = PassthroughArguments.normalize(command)
        guard !normalizedCommand.isEmpty else {
            throw ValidationError("No command specified")
        }

        guard let id = UUID(uuidString: agentId) else {
            throw ValidationError("Invalid agent ID")
        }

        let type = AgentType(rawValue: agentType.lowercased()) ?? .custom
        let config = AppConfig.load()
        let rules = RuleEngine.effectiveRules(config: config)

        // Connect to IPC
        let ipcClient: IPCClient?
        do {
            ipcClient = try IPCClient()
        } catch {
            ipcClient = nil
        }

        let processor = OutputProcessor(
            agentId: id,
            agentType: type,
            displayLabel: label,
            paneId: paneId,
            windowId: windowId,
            sessionName: sessionName,
            rules: rules,
            stallTimeout: config.stallTimeoutSeconds,
            rateLimitLinesPerSec: config.outputRateLimitLinesPerSec
        ) { event in
            try? ipcClient?.send(.event(event))
        }

        // Execute command via PTY
        let pty = try PTYWrapper(command: normalizedCommand[0], arguments: normalizedCommand)

        let outputTask = Task {
            for await data in pty.outputStream() {
                FileHandle.standardOutput.write(data)
                processor.processData(data)
            }
            processor.flush()
        }

        let inputTask = Task.detached {
            let bufSize = 4096
            let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
            defer { buf.deallocate() }
            while true {
                let n = Foundation.read(FileHandle.standardInput.fileDescriptor, buf, bufSize)
                guard n > 0 else { break }
                try? ipcClient?.send(.resume(agentId: id))
                pty.write(Data(bytes: buf, count: n))
            }
        }

        let exitCode = pty.waitForExit()
        outputTask.cancel()
        inputTask.cancel()
        try? ipcClient?.send(.deregister(agentId: id, exitCode: exitCode))
        throw ExitCode(exitCode)
    }
}
