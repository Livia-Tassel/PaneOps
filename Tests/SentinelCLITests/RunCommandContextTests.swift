import XCTest
@testable import SentinelCLI
@testable import SentinelShared

final class RunCommandContextTests: XCTestCase {
    func testRequireTmuxContextRejectsMissingContext() {
        XCTAssertThrowsError(try RunCommand.requireTmuxContext(nil))
    }

    func testRequireTmuxContextRejectsIncompleteContext() {
        let incomplete = PaneInfo(
            paneId: "",
            windowId: "",
            sessionName: "main",
            sessionId: "$1",
            windowName: "editor",
            paneTitle: "",
            panePid: "123",
            paneCurrentPath: "/tmp",
            paneActive: true
        )

        XCTAssertThrowsError(try RunCommand.requireTmuxContext(incomplete))
    }

    func testRequireTmuxContextAcceptsCompleteContext() throws {
        let pane = PaneInfo(
            paneId: "%12",
            windowId: "@3",
            sessionName: "main",
            sessionId: "$1",
            windowName: "editor",
            paneTitle: "",
            panePid: "123",
            paneCurrentPath: "/tmp",
            paneActive: true
        )

        let resolved = try RunCommand.requireTmuxContext(pane)
        XCTAssertEqual(resolved.paneId, "%12")
        XCTAssertEqual(resolved.windowId, "@3")
        XCTAssertEqual(resolved.sessionName, "main")
    }
}
