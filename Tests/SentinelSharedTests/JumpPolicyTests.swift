import XCTest
@testable import SentinelShared

final class JumpPolicyTests: XCTestCase {
    func testAgentAvailabilityRequiresActiveStatusAndPane() {
        let active = AgentInstance(agentType: .claude, paneId: "%10", status: .running)
        XCTAssertTrue(JumpPolicy.availability(for: active).isAvailable)

        let missingPane = AgentInstance(agentType: .claude, paneId: "", status: .running)
        let missing = JumpPolicy.availability(for: missingPane)
        XCTAssertFalse(missing.isAvailable)
        XCTAssertEqual(missing.reason, "Not in tmux")

        let completed = AgentInstance(agentType: .claude, paneId: "%10", status: .completed)
        XCTAssertFalse(JumpPolicy.availability(for: completed).isAvailable)
    }

    func testEventAvailabilityRejectsExpiredAndCompletedEvents() {
        let baseAgentId = UUID()
        let completed = AgentEvent(
            agentId: baseAgentId,
            agentType: .claude,
            displayLabel: "task",
            eventType: .taskCompleted,
            summary: "done",
            matchedRule: "rule",
            paneId: "%10"
        )
        XCTAssertFalse(JumpPolicy.availability(for: completed).isAvailable)

        let expired = AgentEvent(
            agentId: baseAgentId,
            agentType: .claude,
            displayLabel: "task",
            eventType: .stalledOrWaiting,
            summary: "expired",
            matchedRule: "monitor-expire-paneMissing",
            paneId: "%10"
        )
        XCTAssertFalse(JumpPolicy.availability(for: expired).isAvailable)

        let actionable = AgentEvent(
            agentId: baseAgentId,
            agentType: .claude,
            displayLabel: "task",
            eventType: .inputRequested,
            summary: "waiting",
            matchedRule: "rule",
            paneId: "%10"
        )
        XCTAssertTrue(JumpPolicy.availability(for: actionable).isAvailable)
    }
}
