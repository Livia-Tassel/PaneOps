import Foundation
import SentinelShared

@main
struct SentinelMonitorMain {
    static func main() {
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
}
