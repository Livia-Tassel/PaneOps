import Foundation
import SentinelShared

enum MonitorBootstrap {
    static func ensureRunning() {
        if waitForMonitor(retries: 6, retryDelayMicros: 250_000) {
            return
        }

        let candidates = monitorExecutableCandidates()
        for candidate in candidates {
            switch launch(executable: candidate.0, arguments: candidate.1) {
            case .notStarted:
                continue
            case .started(let process):
                if waitForMonitor(retries: 20, retryDelayMicros: 250_000) {
                    SentinelLogger.monitor.info("Launched monitor via \(candidate.0)")
                    return
                }
                if process.isRunning {
                    SentinelLogger.monitor.warning("Monitor launched via \(candidate.0) but did not become ready in time")
                    return
                }
            }
        }

        SentinelLogger.monitor.error("Failed to auto-launch sentinel-monitor; start it manually.")
    }

    private static func monitorExecutableCandidates() -> [(String, [String])] {
        var list: [(String, [String])] = []

        if let exec = Bundle.main.executableURL?.deletingLastPathComponent() {
            let sibling = exec.appendingPathComponent("sentinel-monitor").path
            list.append((sibling, []))
        }

        list.append(("/usr/local/bin/sentinel-monitor", []))
        list.append(("/opt/homebrew/bin/sentinel-monitor", []))
        list.append(("/usr/bin/env", ["sentinel-monitor"]))
        return list
    }

    private static func waitForMonitor(retries: Int, retryDelayMicros: useconds_t) -> Bool {
        for attempt in 0..<retries {
            if let client = try? IPCClient() {
                client.closeConnection()
                return true
            }
            if attempt < retries - 1 {
                usleep(retryDelayMicros)
            }
        }
        return false
    }

    private static func launch(executable: String, arguments: [String]) -> LaunchResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return .started(process)
        } catch {
            return .notStarted
        }
    }
}

private enum LaunchResult {
    case started(Process)
    case notStarted
}
