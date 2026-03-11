import XCTest
@testable import SentinelShared

final class SentinelVersionTests: XCTestCase {
    func testGeneratedVersionMatchesVersionFile() throws {
        let versionURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VERSION")

        let version = try String(contentsOf: versionURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(SentinelVersion.current, version)
    }
}
