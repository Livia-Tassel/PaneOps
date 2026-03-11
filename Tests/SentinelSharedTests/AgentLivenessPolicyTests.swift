import XCTest
@testable import SentinelShared

final class AgentLivenessPolicyTests: XCTestCase {
    func testPaneMissingExpiresAgent() {
        let now = Date()
        let config = AppConfig(activeAgentTTLSeconds: 900)
        let agent = AgentInstance(
            agentType: .claude,
            sessionName: "main",
            paneId: "%10",
            lastActiveAt: now.addingTimeInterval(-5),
            status: .running
        )

        let reason = AgentLivenessPolicy.expirationReason(
            for: agent,
            now: now,
            paneExists: false,
            sessionExists: true,
            config: config,
            isStartupRecovery: false
        )
        XCTAssertEqual(reason, .paneMissing)
    }

    func testHeartbeatTimeoutExpiresAgent() {
        let now = Date()
        let config = AppConfig(activeAgentTTLSeconds: 30)
        let agent = AgentInstance(
            agentType: .claude,
            paneId: "%1",
            lastActiveAt: now.addingTimeInterval(-61),
            status: .waiting
        )

        let reason = AgentLivenessPolicy.expirationReason(
            for: agent,
            now: now,
            paneExists: true,
            sessionExists: true,
            config: config,
            isStartupRecovery: false
        )
        XCTAssertEqual(reason, .heartbeatTimeout)
    }

    func testNoContextUsesStartupGraceDuringRecovery() {
        let now = Date()
        let config = AppConfig(staleAgentGraceSeconds: 20, activeAgentTTLSeconds: 900)
        let agent = AgentInstance(
            agentType: .custom,
            paneId: "",
            lastActiveAt: now.addingTimeInterval(-40),
            status: .running
        )

        let reason = AgentLivenessPolicy.expirationReason(
            for: agent,
            now: now,
            paneExists: nil,
            sessionExists: nil,
            config: config,
            isStartupRecovery: true
        )
        XCTAssertEqual(reason, .noContextTimeout)
    }

    func testCompletedAgentNeverExpires() {
        let now = Date()
        let config = AppConfig(activeAgentTTLSeconds: 1)
        let agent = AgentInstance(
            agentType: .claude,
            paneId: "%2",
            lastActiveAt: now.addingTimeInterval(-500),
            status: .completed
        )

        let reason = AgentLivenessPolicy.expirationReason(
            for: agent,
            now: now,
            paneExists: false,
            sessionExists: false,
            config: config,
            isStartupRecovery: false
        )
        XCTAssertNil(reason)
    }
}
