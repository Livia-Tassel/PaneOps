import ArgumentParser
import Foundation
import SentinelShared

/// `agent-sentinel run` — wraps an agent command with monitoring.
struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command with agent monitoring."
    )

    @Option(name: .long, help: "Agent type (claude, codex, gemini, custom). Auto-detected if omitted.")
    var agent: String?

    @Option(name: .long, help: "Label for this agent instance.")
    var label: String?

    @Flag(name: .long, help: "Enable debug logging of stripped output.")
    var debug: Bool = false

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments to run.")
    var command: [String]

    func run() throws {
        if command == ["--help"] || command == ["-h"] {
            throw CleanExit.helpRequest(self)
        }
        let normalizedCommand = PassthroughArguments.normalize(command)

        guard !normalizedCommand.isEmpty else {
            throw ValidationError("No command specified. Usage: agent-sentinel run -- <command>")
        }

        let agentType: AgentType
        if let agentStr = agent {
            guard let parsed = AgentType(rawValue: agentStr.lowercased()) else {
                throw ValidationError("Unknown agent type: \(agentStr). Use: claude, codex, gemini, custom")
            }
            agentType = parsed
        } else {
            agentType = AgentType.detect(from: normalizedCommand.joined(separator: " "))
        }

        // Gather tmux context (strict requirement).
        let tmux = TmuxClient()
        let paneInfo = try Self.requireTmuxContext(gatherTmuxContext(using: tmux))

        let agentId = UUID()
        let config = AppConfig.load()
        let rules = RuleEngine.effectiveRules(config: config)

        let instance = AgentInstance(
            id: agentId,
            agentType: agentType,
            sessionName: paneInfo.sessionName,
            sessionId: paneInfo.sessionId,
            windowId: paneInfo.windowId,
            paneId: paneInfo.paneId,
            windowName: paneInfo.windowName,
            paneTitle: paneInfo.paneTitle,
            cwd: FileManager.default.currentDirectoryPath,
            taskLabel: label,
            pid: ProcessInfo.processInfo.processIdentifier,
            status: .running
        )

        // Try to connect to the app's IPC server
        let ipcClient = connectToMonitorAndRegister(instance)

        // Set up the PTY wrapper
        let executable = normalizedCommand[0]
        let pty: PTYWrapper
        do {
            pty = try PTYWrapper(command: executable, arguments: normalizedCommand)
        } catch {
            throw ValidationError("Failed to create PTY: \(error)")
        }

        // Set up output processor
        let processor = OutputProcessor(
            agentId: agentId,
            agentType: agentType,
            displayLabel: instance.displayLabel,
            paneId: instance.paneId,
            windowId: instance.windowId,
            sessionName: instance.sessionName,
            rules: rules,
            stallTimeout: config.stallTimeoutSeconds,
            rateLimitLinesPerSec: config.outputRateLimitLinesPerSec,
            debugMode: debug || config.debugMode,
            suppressInteractiveUntilFirstInput: agentType != .custom
        ) { event in
            // Forward to IPC
            try? ipcClient?.send(.event(event))
        }

        // Put terminal into raw mode so all keystrokes pass through
        _ = pty.enableRawMode()

        // Read output and pass to terminal + processor
        let outputTask = Task {
            for await data in pty.outputStream() {
                // Write to our stdout so the user sees output
                FileHandle.standardOutput.write(data)
                processor.processData(data)
            }
            processor.flush()
        }

        let heartbeatTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                try? ipcClient?.send(.heartbeat(agentId: agentId))
            }
        }

        // Pass stdin to the PTY
        let inputTask = Task.detached {
            let bufferSize = 4096
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
            defer { buffer.deallocate() }
            while true {
                let bytesRead = Foundation.read(FileHandle.standardInput.fileDescriptor, buffer, bufferSize)
                guard bytesRead > 0 else { break }
                let data = Data(bytes: buffer, count: bytesRead)
                processor.noteUserInput(data)
                pty.write(data)
            }
        }

        // Wait for child to exit
        let exitCode = pty.waitForExit()

        // Restore terminal before any output
        pty.restoreTerminal()

        outputTask.cancel()
        inputTask.cancel()
        heartbeatTask.cancel()

        // Send deregister
        try? ipcClient?.send(.deregister(agentId: agentId, exitCode: exitCode))

        // Forward exit code
        Darwin.exit(exitCode)
    }

    private func connectToMonitorAndRegister(_ instance: AgentInstance) -> IPCClient? {
        if let client = tryConnectMonitor() {
            try? client.send(.register(instance))
            return client
        }

        launchMonitorIfNeeded()
        if let client = tryConnectMonitor(retries: 6, retryDelayMillis: 250) {
            try? client.send(.register(instance))
            return client
        }

        SentinelLogger.monitor.warning("Could not connect to sentinel-monitor; continuing without app notifications.")
        return nil
    }

    private func tryConnectMonitor(retries: Int = 1, retryDelayMillis: UInt64 = 0) -> IPCClient? {
        for attempt in 0..<retries {
            if let client = try? IPCClient() {
                return client
            }
            if attempt < retries - 1, retryDelayMillis > 0 {
                usleep(useconds_t(retryDelayMillis * 1000))
            }
        }
        return nil
    }

    private func launchMonitorIfNeeded() {
        var candidates: [(String, [String])] = []
        let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append((executablePath.appendingPathComponent("sentinel-monitor").path, []))
        candidates.append(("/usr/local/bin/sentinel-monitor", []))
        candidates.append(("/opt/homebrew/bin/sentinel-monitor", []))
        candidates.append(("/usr/bin/env", ["sentinel-monitor"]))
        for candidate in candidates {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: candidate.0)
            process.arguments = candidate.1
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                usleep(200_000)
                if process.isRunning || process.terminationStatus == 0 {
                    return
                }
            } catch {
                continue
            }
        }
    }

    private func gatherTmuxContext(using tmux: TmuxClient) -> PaneInfo? {
        let env = ProcessInfo.processInfo.environment
        if let paneId = env["TMUX_PANE"], !paneId.isEmpty {
            if let pane = tmux.paneInfo(for: paneId) {
                return pane
            }
            if let pane = fallbackPaneInfo(using: tmux, paneId: paneId) {
                return pane
            }
        }

        if let current = tmux.currentPane() {
            return current
        }

        if let fallbackPaneId = tmux.displayValue(format: "#{pane_id}"),
           !fallbackPaneId.isEmpty {
            return fallbackPaneInfo(using: tmux, paneId: fallbackPaneId)
        }
        return nil
    }

    static func requireTmuxContext(_ paneInfo: PaneInfo?) throws -> PaneInfo {
        guard let paneInfo else {
            throw ValidationError(
                """
                agent-sentinel run must be launched inside a tmux pane.
                Start tmux first, then run: agent-sentinel run -- <command>
                """
            )
        }
        guard !paneInfo.paneId.isEmpty else {
            throw ValidationError(
                """
                Failed to resolve tmux pane id.
                Please run inside an attached tmux pane and retry.
                """
            )
        }
        return paneInfo
    }

    private func fallbackPaneInfo(using tmux: TmuxClient, paneId: String) -> PaneInfo? {
        guard !paneId.isEmpty else { return nil }

        let sessionName = tmux.displayValue(format: "#{session_name}", target: paneId)
            ?? tmux.displayValue(format: "#{session_name}")
            ?? ""
        let sessionId = tmux.displayValue(format: "#{session_id}", target: paneId)
            ?? tmux.displayValue(format: "#{session_id}")
            ?? ""
        let windowId = tmux.displayValue(format: "#{window_id}", target: paneId)
            ?? tmux.displayValue(format: "#{window_id}")
            ?? ""
        let windowName = tmux.displayValue(format: "#{window_name}", target: paneId)
            ?? tmux.displayValue(format: "#{window_name}")
            ?? ""
        let paneTitle = tmux.displayValue(format: "#{pane_title}", target: paneId)
            ?? tmux.displayValue(format: "#{pane_title}")
            ?? ""

        return PaneInfo(
            paneId: paneId,
            windowId: windowId,
            sessionName: sessionName,
            sessionId: sessionId,
            windowName: windowName,
            paneTitle: paneTitle,
            panePid: "",
            paneCurrentPath: FileManager.default.currentDirectoryPath,
            paneActive: true
        )
    }
}
