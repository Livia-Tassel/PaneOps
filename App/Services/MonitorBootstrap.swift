import Foundation
import SentinelShared

enum MonitorBootstrap {
    static func ensureRunning() {
        if let client = try? IPCClient() {
            client.closeConnection()
            return
        }

        let candidates = monitorExecutableCandidates()
        for candidate in candidates {
            if launch(executable: candidate.0, arguments: candidate.1) {
                SentinelLogger.monitor.info("Launched monitor via \(candidate.0)")
                return
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

    private static func launch(executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            usleep(200_000)
            if process.isRunning || process.terminationStatus == 0 {
                return true
            }
            return false
        } catch {
            return false
        }
    }
}
