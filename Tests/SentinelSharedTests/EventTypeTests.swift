import XCTest
@testable import SentinelShared

final class EventTypeTests: XCTestCase {
    func testOverlayManualDismissPolicy() {
        XCTAssertTrue(EventType.permissionRequested.requiresManualDismissInOverlay)
        XCTAssertTrue(EventType.inputRequested.requiresManualDismissInOverlay)
        XCTAssertTrue(EventType.taskCompleted.requiresManualDismissInOverlay)
        XCTAssertFalse(EventType.errorDetected.requiresManualDismissInOverlay)
        XCTAssertFalse(EventType.stalledOrWaiting.requiresManualDismissInOverlay)
    }

    func testAgentEventDecodesWithoutContextLines() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","agentId":"00000000-0000-0000-0000-000000000002","agentType":"claude","displayLabel":"test","eventType":"permissionRequested","summary":"Do you want?","matchedRule":"test-rule","timestamp":"2026-01-01T00:00:00Z","acknowledged":false}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(AgentEvent.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(event.summary, "Do you want?")
        XCTAssertNil(event.contextLines)
    }
}
