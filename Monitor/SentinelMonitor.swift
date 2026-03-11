import Foundation
import SentinelShared

enum MonitorLaunchMode: Equatable {
    case run
    case help
    case version
}

@main
struct SentinelMonitorMain {
    static let version = "0.1.0"

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let mode: MonitorLaunchMode

        do {
            mode = try parseMode(arguments)
        } catch {
            fputs("sentinel-monitor: \(error.localizedDescription)\n", stderr)
            printHelp()
            Darwin.exit(2)
        }

        switch mode {
        case .help:
            printHelp()
            return
        case .version:
            print("sentinel-monitor \(version)")
            return
        case .run:
            runDaemon()
        }
    }

    static func parseMode(_ arguments: [String]) throws -> MonitorLaunchMode {
        if arguments.isEmpty { return .run }
        if arguments.count == 1 {
            switch arguments[0] {
            case "run":
                return .run
            case "-h", "--help", "help":
                return .help
            case "-v", "--version", "version":
                return .version
            default:
                throw NSError(domain: "SentinelMonitorArgs", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "unknown argument '\(arguments[0])'"])
            }
        }
        throw NSError(domain: "SentinelMonitorArgs", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "too many arguments"])
    }

    private static func runDaemon() {
        do {
            try AppConfig.ensureDirectory()
        } catch {
            fputs("sentinel-monitor: failed to initialize config directory: \(error)\n", stderr)
            Darwin.exit(1)
        }

        let state = MonitorState()
        let server = IPCServer(socketPath: AppConfig.socketPath) { message, connection in
            Task {
                await state.handle(message, from: connection)
            }
        }

        Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await state.tickForStalledAgents()
            }
        }

        do {
            SentinelLogger.monitor.info("sentinel-monitor starting on socket \(AppConfig.socketPath)")
            try server.start()
        } catch {
            fputs("sentinel-monitor: server error: \(error)\n", stderr)
            Darwin.exit(1)
        }
    }

    private static func printHelp() {
        print(
            """
            OVERVIEW: Local monitor daemon for Agent Sentinel.

            USAGE: sentinel-monitor [run]

            OPTIONS:
              -h, --help       Show help information.
              -v, --version    Show version.
            """
        )
    }
}
