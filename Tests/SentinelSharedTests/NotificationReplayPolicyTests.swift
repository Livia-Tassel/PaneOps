import XCTest
@testable import SentinelShared

final class NotificationReplayPolicyTests: XCTestCase {
    func testReplayableCompletionEventsFiltersByWindowAndShownSet() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fresh = AgentEvent(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "fresh",
            eventType: .taskCompleted,
            summary: "done",
            matchedRule: "rule",
            shouldNotify: true,
            timestamp: now.addingTimeInterval(-10)
        )
        let old = AgentEvent(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "old",
            eventType: .taskCompleted,
            summary: "done",
            matchedRule: "rule",
            shouldNotify: true,
            timestamp: now.addingTimeInterval(-40)
        )
        let hidden = AgentEvent(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "hidden",
            eventType: .taskCompleted,
            summary: "done",
            matchedRule: "rule",
            shouldNotify: false,
            timestamp: now.addingTimeInterval(-5)
        )
        let nonCompletion = AgentEvent(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "input",
            eventType: .inputRequested,
            summary: "input",
            matchedRule: "rule",
            shouldNotify: true,
            timestamp: now.addingTimeInterval(-5)
        )

        let replayable = NotificationReplayPolicy.replayableCompletionEvents(
            from: [old, hidden, nonCompletion, fresh],
            now: now,
            replayWindowSeconds: 30,
            alreadyShownEventIDs: [fresh.id]
        )

        XCTAssertTrue(replayable.isEmpty)
    }

    func testReplayableCompletionEventsSortedByTimestamp() {
        let now = Date(timeIntervalSince1970: 2_000)
        let older = AgentEvent(
            agentId: UUID(),
            agentType: .codex,
            displayLabel: "older",
            eventType: .taskCompleted,
            summary: "older",
            matchedRule: "rule",
            shouldNotify: true,
            timestamp: now.addingTimeInterval(-20)
        )
        let newer = AgentEvent(
            agentId: UUID(),
            agentType: .codex,
            displayLabel: "newer",
            eventType: .taskCompleted,
            summary: "newer",
            matchedRule: "rule",
            shouldNotify: true,
            timestamp: now.addingTimeInterval(-5)
        )

        let replayable = NotificationReplayPolicy.replayableCompletionEvents(
            from: [newer, older],
            now: now,
            replayWindowSeconds: 30,
            alreadyShownEventIDs: []
        )

        XCTAssertEqual(replayable.map(\.id), [older.id, newer.id])
    }
}
