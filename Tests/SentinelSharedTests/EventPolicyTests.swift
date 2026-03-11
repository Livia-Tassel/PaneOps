import XCTest
@testable import SentinelShared

final class EventPolicyTests: XCTestCase {
    func testTaskCompletedIsNotActionable() {
        let event = AgentEvent(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "task",
            eventType: .taskCompleted,
            summary: "done",
            matchedRule: "done-rule"
        )

        XCTAssertFalse(
            EventPolicy.isActionable(
                event,
                now: Date(),
                actionableWindowSeconds: 3600
            )
        )
    }

    func testOldPermissionEventIsNotActionable() {
        let oldDate = Date().addingTimeInterval(-7200)
        let event = AgentEvent(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "task",
            eventType: .permissionRequested,
            summary: "allow?",
            matchedRule: "perm",
            timestamp: oldDate
        )

        XCTAssertFalse(
            EventPolicy.isActionable(
                event,
                now: Date(),
                actionableWindowSeconds: 1800
            )
        )
    }

    func testNormalizeHistoryAcknowledgesCompletedAndOldEvents() {
        let now = Date()
        let completed = AgentEvent(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "c1",
            eventType: .taskCompleted,
            summary: "done",
            matchedRule: "done",
            timestamp: now
        )
        let oldError = AgentEvent(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "c2",
            eventType: .errorDetected,
            summary: "err",
            matchedRule: "err",
            timestamp: now.addingTimeInterval(-4000)
        )
        let activePermission = AgentEvent(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "c3",
            eventType: .permissionRequested,
            summary: "allow?",
            matchedRule: "perm",
            timestamp: now.addingTimeInterval(-5)
        )

        let normalized = EventPolicy.normalizeHistory(
            [completed, oldError, activePermission],
            now: now,
            actionableWindowSeconds: 300
        )

        XCTAssertTrue(normalized[0].acknowledged)
        XCTAssertTrue(normalized[1].acknowledged)
        XCTAssertFalse(normalized[2].acknowledged)
    }

    func testCanonicalSummaryNormalizesNumbers() {
        let one = EventPolicy.canonicalSummary("No output for 120s — wait")
        let two = EventPolicy.canonicalSummary("No output for 240s — wait")
        XCTAssertEqual(one, two)
    }

    func testInactiveAgentInputEventIsNotActionableWhenActiveSetProvided() {
        let activeAgentId = UUID()
        let inactiveAgentEvent = AgentEvent(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "inactive",
            eventType: .inputRequested,
            summary: "Need input",
            matchedRule: "rule"
        )

        XCTAssertFalse(
            EventPolicy.isActionable(
                inactiveAgentEvent,
                now: Date(),
                actionableWindowSeconds: 3600,
                activeAgentIDs: [activeAgentId]
            )
        )
    }

    func testLegacyClaudePromptReadyInputGetsAcknowledgedOnNormalize() {
        let event = AgentEvent(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "task",
            eventType: .inputRequested,
            summary: "❯",
            matchedRule: "Claude: Prompt ready (❯)"
        )

        let normalized = EventPolicy.normalizeHistory(
            [event],
            now: Date(),
            actionableWindowSeconds: 3600
        )
        XCTAssertTrue(normalized[0].acknowledged)
    }
}
