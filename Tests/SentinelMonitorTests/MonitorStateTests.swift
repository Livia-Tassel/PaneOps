import XCTest
@testable import SentinelMonitor
@testable import SentinelShared

final class MonitorStateTests: XCTestCase {
    func testHeartbeatDoesNotRecoverStalledAgentUntilResume() async throws {
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
        let heartbeatMessages = try sockets.readMessages(count: 1)
        XCTAssertTrue(heartbeatMessages.contains(where: { message in
            if case .heartbeat(let recoveredId) = message {
                return recoveredId == agent.id
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
        XCTAssertThrowsError(try sockets.readMessages(count: 1))

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
                return messageId == firstStall.id
            }
            return false
        }))

        clock.advance(by: 61)
        let thirdStall = AgentEvent(
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

        await state.handle(.event(thirdStall), from: sockets.connection)
        let repeatedBroadcast = try sockets.readMessages(count: 1)
        guard case .event(let repeatedStallEvent) = repeatedBroadcast[0] else {
            return XCTFail("Expected repeated stall event broadcast after explicit resume")
        }
        XCTAssertEqual(repeatedStallEvent.id, thirdStall.id)
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

    func testActivityRecoversStalledAgentAndAcknowledgesOldStallEvent() async throws {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 3_000))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let agent = AgentInstance(
            agentType: .codex,
            sessionName: "main",
            paneId: "%3",
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

        let stallEvent = AgentEvent(
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

        await state.handle(.event(stallEvent), from: sockets.connection)
        _ = try sockets.readMessages(count: 1)

        clock.advance(by: 1)
        await state.handle(.activity(agentId: agent.id), from: sockets.connection)
        let activityMessages = try sockets.readMessages(count: 2)

        XCTAssertTrue(activityMessages.contains(where: { message in
            if case .activity(let activeId) = message {
                return activeId == agent.id
            }
            return false
        }))
        XCTAssertTrue(activityMessages.contains(where: { message in
            if case .ack(let messageId) = message {
                return messageId == stallEvent.id
            }
            return false
        }))

        clock.advance(by: 61)
        let repeatedStall = AgentEvent(
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

        await state.handle(.event(repeatedStall), from: sockets.connection)
        let repeatedMessages = try sockets.readMessages(count: 1)
        guard case .event(let repeatedEvent) = repeatedMessages[0] else {
            return XCTFail("Expected repeated stall broadcast after output activity recovery")
        }
        XCTAssertEqual(repeatedEvent.id, repeatedStall.id)
    }

    func testRegisterCollapsesOlderActiveAgentOnSamePane() async throws {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 4_000))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let oldAgent = AgentInstance(
            agentType: .claude,
            sessionName: "main",
            paneId: "%17",
            startedAt: clock.now.addingTimeInterval(-120),
            lastActiveAt: clock.now.addingTimeInterval(-30),
            status: .waiting
        )
        let pendingInput = AgentEvent(
            agentId: oldAgent.id,
            agentType: .claude,
            displayLabel: oldAgent.displayLabel,
            eventType: .inputRequested,
            summary: "Awaiting input",
            matchedRule: "Claude: Input prompt",
            shouldNotify: true,
            timestamp: clock.now.addingTimeInterval(-15),
            paneId: oldAgent.paneId,
            sessionName: oldAgent.sessionName,
            acknowledged: false
        )
        let state = MonitorState(
            tmux: TmuxClient(runner: StubCommandRunner(), tmuxExecutable: "/opt/homebrew/bin/tmux"),
            nowProvider: { clock.now },
            config: AppConfig(maxStoredEvents: 20),
            eventStore: EventStore(fileURL: tempDir.appendingPathComponent("events.jsonl"), maxLines: 20),
            initialAgents: [oldAgent.id: oldAgent],
            initialEvents: [pendingInput],
            persistAgents: { _ in }
        )

        let sockets = try SocketPair()
        defer { sockets.close() }

        await state.handle(.subscribe(SubscribeRequest(kind: .app)), from: sockets.connection)
        _ = try sockets.readMessages(count: 1)

        let newAgent = AgentInstance(
            agentType: .claude,
            sessionName: "main",
            paneId: "%17",
            startedAt: clock.now,
            lastActiveAt: clock.now,
            status: .running
        )
        await state.handle(.register(newAgent), from: sockets.connection)
        let registerMessages = try sockets.readMessages(count: 3)

        XCTAssertTrue(registerMessages.contains(where: { message in
            if case .event(let event) = message {
                return event.agentId == oldAgent.id
                    && event.matchedRule == "monitor-expire-paneReplaced"
                    && event.acknowledged
                    && !event.shouldNotify
            }
            return false
        }))
        XCTAssertTrue(registerMessages.contains(where: { message in
            if case .ack(let messageId) = message {
                return messageId == pendingInput.id
            }
            return false
        }))
        XCTAssertTrue(registerMessages.contains(where: { message in
            if case .register(let agent) = message {
                return agent.id == newAgent.id
            }
            return false
        }))

        await state.handle(.subscribe(SubscribeRequest(kind: .app)), from: sockets.connection)
        let snapshotMessages = try sockets.readMessages(count: 1)
        guard case .snapshot(let snapshot) = snapshotMessages[0] else {
            return XCTFail("Expected snapshot")
        }

        let active = snapshot.agents.filter(\.status.isActive)
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.id, newAgent.id)
        let oldInSnapshot = snapshot.agents.first(where: { $0.id == oldAgent.id })
        XCTAssertEqual(oldInSnapshot?.status, .expired)

        let staleCompletion = AgentEvent(
            agentId: oldAgent.id,
            agentType: .claude,
            displayLabel: oldAgent.displayLabel,
            eventType: .taskCompleted,
            summary: "stale completion should be ignored",
            matchedRule: "Claude: Prompt ready (❯)",
            shouldNotify: true,
            timestamp: clock.now.addingTimeInterval(1),
            paneId: oldAgent.paneId,
            sessionName: oldAgent.sessionName
        )
        await state.handle(.event(staleCompletion), from: sockets.connection)

        let staleProbe = try SocketPair()
        defer { staleProbe.close() }
        await state.handle(.subscribe(SubscribeRequest(kind: .app)), from: staleProbe.connection)
        let staleSnapshotMessages = try staleProbe.readMessages(count: 1)
        guard case .snapshot(let staleSnapshot) = staleSnapshotMessages[0] else {
            return XCTFail("Expected snapshot after stale completion")
        }
        let staleActive = staleSnapshot.agents.filter(\.status.isActive)
        XCTAssertEqual(staleActive.count, 1)
        XCTAssertEqual(staleActive.first?.id, newAgent.id)
        XCTAssertNil(staleSnapshot.events.first(where: { $0.id == staleCompletion.id }))

        await state.handle(.deregister(agentId: oldAgent.id, exitCode: 0), from: sockets.connection)

        let finalProbe = try SocketPair()
        defer { finalProbe.close() }
        await state.handle(.subscribe(SubscribeRequest(kind: .app)), from: finalProbe.connection)
        let finalSnapshotMessages = try finalProbe.readMessages(count: 1)
        guard case .snapshot(let finalSnapshot) = finalSnapshotMessages[0] else {
            return XCTFail("Expected final snapshot")
        }
        XCTAssertNil(finalSnapshot.events.first(where: { event in
            event.agentId == oldAgent.id && event.matchedRule == "monitor-exit-success"
        }))
        let finalActive = finalSnapshot.agents.filter(\.status.isActive)
        XCTAssertEqual(finalActive.count, 1)
        XCTAssertEqual(finalActive.first?.id, newAgent.id)
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
