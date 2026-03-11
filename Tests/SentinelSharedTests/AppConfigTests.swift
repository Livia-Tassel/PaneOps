import XCTest
@testable import SentinelShared

final class AppConfigTests: XCTestCase {
    func testNormalizedClampsUnsafeNumericValues() {
        let config = AppConfig(
            stallTimeoutSeconds: -1,
            maxNotifications: 0,
            normalDismissSeconds: -5,
            highDismissSeconds: 0,
            notificationsEnabled: true,
            outputRateLimitLinesPerSec: 0,
            maxStoredEvents: -10,
            eventDedupeWindowSeconds: -3,
            staleAgentGraceSeconds: 0,
            activeAgentTTLSeconds: -20,
            actionableEventWindowSeconds: 0
        )

        XCTAssertEqual(config.stallTimeoutSeconds, 5)
        XCTAssertEqual(config.maxNotifications, 1)
        XCTAssertEqual(config.normalDismissSeconds, 1)
        XCTAssertEqual(config.highDismissSeconds, 1)
        XCTAssertEqual(config.outputRateLimitLinesPerSec, 1)
        XCTAssertEqual(config.maxStoredEvents, 1)
        XCTAssertEqual(config.eventDedupeWindowSeconds, 0)
        XCTAssertEqual(config.staleAgentGraceSeconds, 1)
        XCTAssertEqual(config.activeAgentTTLSeconds, 30)
        XCTAssertEqual(config.actionableEventWindowSeconds, 60)
    }
}
