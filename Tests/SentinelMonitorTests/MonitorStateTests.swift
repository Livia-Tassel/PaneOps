import XCTest
@testable import SentinelMonitor
@testable import SentinelShared

final class MonitorStateTests: XCTestCase {
    func testHeartbeatRecoversAgentAcknowledgesOldStallAndAllowsFutureStallAlerts() async throws {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_000))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let agent = AgentInstance(
            agentType: .codex,
            sessionName: "main",
            paneId: "%1",
            lastActiveAt: clock.now,
            status: .running
        )
        let config = AppConfig(maxStoredEvents: 20, eventDedupeWindowSeconds: 6)
        let state = MonitorState(
            tmux: TmuxClient(runner: StubCommandRunner(), tmuxExecutable: "/opt/homebrew/bin/tmux"),
            nowProvider: { clock.now },
            config: config,
            eventStore: EventStore(fileURL: tempDir.appendingPathComponent("events.jsonl"), maxLines: 20),
            initialAgents: [agent.id: agent],
            initialEvents: [],
            persistAgents: { _ in }
        )

        let sockets = try SocketPair()
        defer { sockets.close() }

        await state.handle(.subscribe(SubscribeRequest(kind: .app)), from: sockets.connection)
        let initialMessages = try sockets.readMessages(count: 1)
        guard case .snapshot = initialMessages[0] else {
            return XCTFail("Expected initial snapshot")
        }

        let firstStall = AgentEvent(
            agentId: agent.id,
            agentType: .codex,
            displayLabel: "codex",
            eventType: .stalledOrWaiting,
            summary: "No output for 120s — agent may be stalled or waiting",
            matchedRule: "stall-detection",
            timestamp: clock.now,
            paneId: agent.paneId,
            sessionName: agent.sessionName
        )

        await state.handle(.event(firstStall), from: sockets.connection)
        let firstBroadcast = try sockets.readMessages(count: 1)
        guard case .event(let stalledEvent) = firstBroadcast[0] else {
            return XCTFail("Expected stall event broadcast")
        }
        XCTAssertEqual(stalledEvent.id, firstStall.id)

        clock.advance(by: 5)
        await state.handle(.heartbeat(agentId: agent.id), from: sockets.connection)
        let recoveryMessages = try sockets.readMessages(count: 2)

        XCTAssertTrue(recoveryMessages.contains(where: { message in
            if case .heartbeat(let recoveredId) = message {
                return recoveredId == agent.id
            }
            return false
        }))
        XCTAssertTrue(recoveryMessages.contains(where: { message in
            if case .ack(let messageId) = message {
                return messageId == firstStall.id
            }
            return false
        }))

        clock.advance(by: 61)
        let secondStall = AgentEvent(
            agentId: agent.id,
            agentType: .codex,
            displayLabel: "codex",
            eventType: .stalledOrWaiting,
            summary: "No output for 120s — agent may be stalled or waiting",
            matchedRule: "stall-detection",
            timestamp: clock.now,
            paneId: agent.paneId,
            sessionName: agent.sessionName
        )

        await state.handle(.event(secondStall), from: sockets.connection)
        let secondBroadcast = try sockets.readMessages(count: 1)
        guard case .event(let repeatedStallEvent) = secondBroadcast[0] else {
            return XCTFail("Expected repeated stall event broadcast after recovery")
        }
        XCTAssertEqual(repeatedStallEvent.id, secondStall.id)
    }

    func testResumeRecoversWaitingAgentAndAcknowledgesInputEvent() async throws {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 2_000))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let agent = AgentInstance(
            agentType: .claude,
            sessionName: "main",
            paneId: "%2",
            lastActiveAt: clock.now,
            status: .running
        )
        let state = MonitorState(
            tmux: TmuxClient(runner: StubCommandRunner(), tmuxExecutable: "/opt/homebrew/bin/tmux"),
            nowProvider: { clock.now },
            config: AppConfig(maxStoredEvents: 20),
            eventStore: EventStore(fileURL: tempDir.appendingPathComponent("events.jsonl"), maxLines: 20),
            initialAgents: [agent.id: agent],
            initialEvents: [],
            persistAgents: { _ in }
        )

        let sockets = try SocketPair()
        defer { sockets.close() }

        await state.handle(.subscribe(SubscribeRequest(kind: .app)), from: sockets.connection)
        _ = try sockets.readMessages(count: 1)

        let inputEvent = AgentEvent(
            agentId: agent.id,
            agentType: .claude,
            displayLabel: "claude",
            eventType: .inputRequested,
            summary: "Press enter to continue",
            matchedRule: "Claude: Input prompt",
            timestamp: clock.now,
            paneId: agent.paneId,
            sessionName: agent.sessionName
        )

        await state.handle(.event(inputEvent), from: sockets.connection)
        _ = try sockets.readMessages(count: 1)

        clock.advance(by: 1)
        await state.handle(.resume(agentId: agent.id), from: sockets.connection)
        let resumeMessages = try sockets.readMessages(count: 2)

        XCTAssertTrue(resumeMessages.contains(where: { message in
            if case .resume(let resumedId) = message {
                return resumedId == agent.id
            }
            return false
        }))
        XCTAssertTrue(resumeMessages.contains(where: { message in
            if case .ack(let messageId) = message {
                return messageId == inputEvent.id
            }
            return false
        }))
    }
}

private final class MutableClock: @unchecked Sendable {
    var now: Date

    init(start: Date) {
        self.now = start
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

private struct SocketPair {
    let connection: IPCServer.ClientConnection
    let peerFD: Int32

    init() throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        connection = IPCServer.ClientConnection(fd: fds[0])
        peerFD = fds[1]

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(peerFD, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    func close() {
        connection.close()
        Darwin.close(peerFD)
    }

    func readMessages(count expectedCount: Int) throws -> [IPCMessage] {
        var buffer = Data()
        var messages: [IPCMessage] = []
        let chunkSize = 4096
        let chunk = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 1)
        defer { chunk.deallocate() }

        while messages.count < expectedCount {
            let bytesRead = recv(peerFD, chunk, chunkSize, 0)
            if bytesRead < 0, errno == EINTR {
                continue
            }
            guard bytesRead > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ETIMEDOUT)
            }

            buffer.append(chunk.assumingMemoryBound(to: UInt8.self), count: bytesRead)
            while let (message, consumed) = try IPCFraming.decode(from: buffer) {
                messages.append(message)
                buffer.removeFirst(consumed)
                if messages.count == expectedCount {
                    break
                }
            }
        }

        return messages
    }
}

private struct StubCommandRunner: CommandRunning {
    func run(executable: String, arguments: [String], environment: [String: String]?) -> CommandResult {
        CommandResult(stdout: "", stderr: "", exitCode: 0)
    }
}
