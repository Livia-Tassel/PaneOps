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
}
