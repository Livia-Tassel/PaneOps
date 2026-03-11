import XCTest
@testable import SentinelCLI

final class PassthroughArgumentsTests: XCTestCase {
    func testOnlyLeadingSeparatorIsRemoved() {
        XCTAssertEqual(
            PassthroughArguments.normalize(["--", "claude", "--", "--dangerous"]),
            ["claude", "--", "--dangerous"]
        )
    }

    func testNoLeadingSeparatorLeavesArgsUntouched() {
        XCTAssertEqual(
            PassthroughArguments.normalize(["codex", "--", "arg"]),
            ["codex", "--", "arg"]
        )
    }
}
