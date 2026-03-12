import Foundation
import SentinelShared
import Darwin

enum MonitorLaunchMode: Equatable {
    case run
    case help
    case version
}

@main
struct SentinelMonitorMain {
    static let version = SentinelVersion.current
    private static var instanceLockFD: Int32 = -1

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

        do {
            instanceLockFD = try acquireInstanceLock()
        } catch {
            fputs("sentinel-monitor: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }

        let state = MonitorState()
        let server = IPCServer(
            socketPath: AppConfig.socketPath,
            handler: { message, connection in
                Task {
                    await state.handle(message, from: connection)
                }
            },
            disconnectHandler: { connection in
                Task {
                    await state.clientDisconnected(connection)
                }
            }
        )

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

    private static func acquireInstanceLock() throws -> Int32 {
        let lockPath = AppConfig.baseDirectory.appendingPathComponent("monitor.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw NSError(
                domain: "SentinelMonitorLock",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "failed to open monitor lock file"]
            )
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let lockErrno = errno
            close(fd)
            if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
                throw NSError(
                    domain: "SentinelMonitorLock",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "another sentinel-monitor instance is already running"]
                )
            }
            throw NSError(
                domain: "SentinelMonitorLock",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "failed to lock monitor instance file (\(lockErrno))"]
            )
        }
        return fd
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
