import XCTest
@testable import SentinelShared

final class AgentInstanceTests: XCTestCase {
    func testHeartbeatPreservesStalledStatus() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let heartbeatAt = Date(timeIntervalSince1970: 120)
        var agent = AgentInstance(
            agentType: .codex,
            paneId: "%1",
            startedAt: startedAt,
            lastActiveAt: startedAt,
            status: .stalled
        )

        agent.recordHeartbeat(at: heartbeatAt)

        XCTAssertEqual(agent.status, .stalled)
        XCTAssertEqual(agent.lastActiveAt, heartbeatAt)
    }

    func testHeartbeatPreservesWaitingStatus() {
        let heartbeatAt = Date(timeIntervalSince1970: 220)
        var agent = AgentInstance(
            agentType: .claude,
            paneId: "%2",
            lastActiveAt: Date(timeIntervalSince1970: 200),
            status: .waiting
        )

        agent.recordHeartbeat(at: heartbeatAt)

        XCTAssertEqual(agent.status, .waiting)
        XCTAssertEqual(agent.lastActiveAt, heartbeatAt)
    }

    func testApplyExpirationEventMarksAgentExpired() {
        let eventTime = Date(timeIntervalSince1970: 330)
        var agent = AgentInstance(
            agentType: .gemini,
            paneId: "%3",
            lastActiveAt: Date(timeIntervalSince1970: 300),
            status: .running
        )
        let event = AgentEvent(
            agentId: agent.id,
            agentType: agent.agentType,
            displayLabel: "test",
            eventType: .stalledOrWaiting,
            summary: "Agent expired: heartbeat inactive for too long",
            matchedRule: "monitor-expire-heartbeatTimeout",
            shouldNotify: false,
            timestamp: eventTime,
            paneId: agent.paneId
        )

        agent.apply(event: event)

        XCTAssertEqual(agent.status, .expired)
        XCTAssertEqual(agent.lastActiveAt, eventTime)
    }

    func testApplyErrorEventDoesNotDeactivateRunningAgent() {
        let eventTime = Date(timeIntervalSince1970: 430)
        var agent = AgentInstance(
            agentType: .claude,
            paneId: "%4",
            lastActiveAt: Date(timeIntervalSince1970: 400),
            status: .running
        )
        let event = AgentEvent(
            agentId: agent.id,
            agentType: agent.agentType,
            displayLabel: "test",
            eventType: .errorDetected,
            summary: "Error: retrying",
            matchedRule: "Claude: Error",
            timestamp: eventTime,
            paneId: agent.paneId
        )

        agent.apply(event: event)

        XCTAssertEqual(agent.status, .running)
        XCTAssertEqual(agent.lastActiveAt, eventTime)
    }

    func testResumeRestoresWaitingAgentToRunning() {
        let resumeAt = Date(timeIntervalSince1970: 520)
        var agent = AgentInstance(
            agentType: .codex,
            paneId: "%5",
            lastActiveAt: Date(timeIntervalSince1970: 500),
            status: .waiting
        )

        agent.recordResume(at: resumeAt)

        XCTAssertEqual(agent.status, .running)
        XCTAssertEqual(agent.lastActiveAt, resumeAt)
    }
}
