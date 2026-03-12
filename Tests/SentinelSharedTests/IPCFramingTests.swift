import XCTest
@testable import SentinelShared

final class IPCFramingTests: XCTestCase {
    func testRoundtripRegister() throws {
        let agent = AgentInstance(
            agentType: .claude,
            sessionName: "main",
            paneId: "%5",
            windowName: "editor",
            taskLabel: "auth-fix"
        )
        let message = IPCMessage.register(agent)

        let encoded = try IPCFraming.encode(message)
        let (decoded, consumed) = try XCTUnwrap(IPCFraming.decode(from: encoded))

        XCTAssertEqual(consumed, encoded.count)
        if case .register(let decodedAgent) = decoded {
            XCTAssertEqual(decodedAgent.id, agent.id)
            XCTAssertEqual(decodedAgent.agentType, .claude)
            XCTAssertEqual(decodedAgent.taskLabel, "auth-fix")
            XCTAssertEqual(decodedAgent.paneId, "%5")
        } else {
            XCTFail("Expected register message")
        }
    }

    func testRoundtripEvent() throws {
        let event = AgentEvent(
            agentId: UUID(),
            agentType: .codex,
            displayLabel: "test",
            eventType: .permissionRequested,
            summary: "Do you want to proceed?",
            matchedRule: "Claude: Permission"
        )
        let message = IPCMessage.event(event)

        let encoded = try IPCFraming.encode(message)
        let (decoded, _) = try XCTUnwrap(IPCFraming.decode(from: encoded))

        if case .event(let decodedEvent) = decoded {
            XCTAssertEqual(decodedEvent.id, event.id)
            XCTAssertEqual(decodedEvent.eventType, .permissionRequested)
            XCTAssertEqual(decodedEvent.summary, "Do you want to proceed?")
        } else {
            XCTFail("Expected event message")
        }
    }

    func testRoundtripDeregister() throws {
        let agentId = UUID()
        let message = IPCMessage.deregister(agentId: agentId, exitCode: 0)

        let encoded = try IPCFraming.encode(message)
        let (decoded, _) = try XCTUnwrap(IPCFraming.decode(from: encoded))

        if case .deregister(let id, let code) = decoded {
            XCTAssertEqual(id, agentId)
            XCTAssertEqual(code, 0)
        } else {
            XCTFail("Expected deregister message")
        }
    }

    func testRoundtripHeartbeat() throws {
        let agentId = UUID()
        let message = IPCMessage.heartbeat(agentId: agentId)

        let encoded = try IPCFraming.encode(message)
        let (decoded, _) = try XCTUnwrap(IPCFraming.decode(from: encoded))

        if case .heartbeat(let id) = decoded {
            XCTAssertEqual(id, agentId)
        } else {
            XCTFail("Expected heartbeat message")
        }
    }

    func testRoundtripResume() throws {
        let agentId = UUID()
        let message = IPCMessage.resume(agentId: agentId)

        let encoded = try IPCFraming.encode(message)
        let (decoded, _) = try XCTUnwrap(IPCFraming.decode(from: encoded))

        if case .resume(let id) = decoded {
            XCTAssertEqual(id, agentId)
        } else {
            XCTFail("Expected resume message")
        }
    }

    func testRoundtripAck() throws {
        let msgId = UUID()
        let message = IPCMessage.ack(messageId: msgId)

        let encoded = try IPCFraming.encode(message)
        let (decoded, _) = try XCTUnwrap(IPCFraming.decode(from: encoded))

        if case .ack(let id) = decoded {
            XCTAssertEqual(id, msgId)
        } else {
            XCTFail("Expected ack message")
        }
    }

    func testRoundtripSubscribe() throws {
        let request = SubscribeRequest(kind: .app)
        let message = IPCMessage.subscribe(request)
        let encoded = try IPCFraming.encode(message)
        let (decoded, _) = try XCTUnwrap(IPCFraming.decode(from: encoded))

        if case .subscribe(let decodedRequest) = decoded {
            XCTAssertEqual(decodedRequest.kind, .app)
            XCTAssertEqual(decodedRequest.clientId, request.clientId)
        } else {
            XCTFail("Expected subscribe message")
        }
    }

    func testRoundtripSnapshot() throws {
        let snapshot = MonitorSnapshot(
            agents: [AgentInstance(agentType: .claude, paneId: "%1")],
            events: [AgentEvent(
                agentId: UUID(),
                agentType: .claude,
                displayLabel: "task",
                eventType: .taskCompleted,
                summary: "done",
                matchedRule: "test"
            )],
            config: AppConfig()
        )
        let message = IPCMessage.snapshot(snapshot)
        let encoded = try IPCFraming.encode(message)
        let (decoded, _) = try XCTUnwrap(IPCFraming.decode(from: encoded))

        if case .snapshot(let decodedSnapshot) = decoded {
            XCTAssertEqual(decodedSnapshot.agents.count, 1)
            XCTAssertEqual(decodedSnapshot.events.count, 1)
            XCTAssertEqual(decodedSnapshot.config.maxNotifications, snapshot.config.maxNotifications)
        } else {
            XCTFail("Expected snapshot message")
        }
    }

    func testRoundtripMaintenance() throws {
        let request = MaintenanceRequest(action: .clearEventHistory)
        let message = IPCMessage.maintenance(request)
        let encoded = try IPCFraming.encode(message)
        let (decoded, _) = try XCTUnwrap(IPCFraming.decode(from: encoded))

        if case .maintenance(let decodedRequest) = decoded {
            XCTAssertEqual(decodedRequest.action, .clearEventHistory)
        } else {
            XCTFail("Expected maintenance message")
        }
    }

    func testIncompleteBuffer() throws {
        let agent = AgentInstance(agentType: .claude)
        let encoded = try IPCFraming.encode(.register(agent))

        // Only first 3 bytes — not enough for length prefix
        let partial = encoded.prefix(3)
        XCTAssertNil(try IPCFraming.decode(from: Data(partial)))

        // Length prefix present but body truncated
        let partial2 = encoded.prefix(10)
        XCTAssertNil(try IPCFraming.decode(from: Data(partial2)))
    }

    func testMultipleFrames() throws {
        let msg1 = IPCMessage.heartbeat(agentId: UUID())
        let msg2 = IPCMessage.ack(messageId: UUID())

        var buffer = try IPCFraming.encode(msg1)
        buffer.append(try IPCFraming.encode(msg2))

        // Decode first
        let (decoded1, consumed1) = try XCTUnwrap(IPCFraming.decode(from: buffer))
        if case .heartbeat = decoded1 {} else { XCTFail("Expected heartbeat") }

        // Decode second from remaining
        let remaining = buffer.subdata(in: consumed1..<buffer.count)
        let (decoded2, _) = try XCTUnwrap(IPCFraming.decode(from: remaining))
        if case .ack = decoded2 {} else { XCTFail("Expected ack") }
    }

    func testRejectsOversizedFrameLength() {
        // Length prefix: 0x00400001 (4MB + 1)
        var data = Data([0x00, 0x40, 0x00, 0x01])
        data.append(Data(repeating: 0, count: 8))

        XCTAssertThrowsError(try IPCFraming.decode(from: data)) { error in
            guard case IPCError.decodingFailed = error else {
                return XCTFail("Expected decodingFailed, got \(error)")
            }
        }
    }
}
