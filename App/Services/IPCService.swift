import Foundation
import SentinelShared

/// App-side subscription client for the monitor daemon.
final class IPCService: ObservableObject, @unchecked Sendable {
    var onMessage: (@Sendable (IPCMessage) -> Void)?
    var onConnectionChanged: (@Sendable (Bool) -> Void)?

    private var client: IPCClient?
    private var runTask: Task<Void, Never>?
    private let stateQueue = DispatchQueue(label: "com.paneops.agent-sentinel.app.ipc")
    private let subscribeRequest = SubscribeRequest(kind: .app)
    private var shouldRun = false

    func start() {
        stateQueue.sync {
            shouldRun = true
        }

        runTask = Task.detached { [weak self] in
            await self?.connectionLoop()
        }
    }

    func stop() {
        let localClient = stateQueue.sync { () -> IPCClient? in
            shouldRun = false
            defer { client = nil }
            return client
        }

        runTask?.cancel()
        localClient?.closeConnection()
    }

    func send(_ message: IPCMessage) {
        let localClient = stateQueue.sync { client }
        do {
            try localClient?.send(message)
        } catch {
            SentinelLogger.ipc.warning("App send failed: \(error.localizedDescription)")
        }
    }

    private func connectionLoop() async {
        while isRunning && !Task.isCancelled {
            do {
                let connected = try IPCClient()
                stateQueue.sync {
                    client = connected
                }

                DispatchQueue.main.async {
                    self.onConnectionChanged?(true)
                }

                try connected.send(.subscribe(subscribeRequest))
                SentinelLogger.ipc.info("App subscribed to monitor stream")

                while isRunning && !Task.isCancelled {
                    let message = try connected.receive()
                    DispatchQueue.main.async {
                        self.onMessage?(message)
                    }
                }
            } catch {
                SentinelLogger.ipc.warning("App IPC disconnected, retrying: \(error.localizedDescription)")
                stateQueue.sync {
                    client?.closeConnection()
                    client = nil
                }

                DispatchQueue.main.async {
                    self.onConnectionChanged?(false)
                }

                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private var isRunning: Bool {
        stateQueue.sync { shouldRun }
    }
}
