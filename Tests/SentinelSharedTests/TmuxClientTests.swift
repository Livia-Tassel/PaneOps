import XCTest
@testable import SentinelShared

final class TmuxClientTests: XCTestCase {
    func testCurrentPaneParsesWhenPaneTitleIsEmpty() {
        let runner = MockTmuxRunner { executable, arguments in
            XCTAssertEqual(executable, "/opt/homebrew/bin/tmux")
            if arguments.contains("display-message") {
                let line = "%12\t@3\tmain\t$1\teditor\t\t12345\t/Users/test\t1\n"
                return CommandResult(stdout: line, stderr: "", exitCode: 0)
            }
            return CommandResult(stdout: "", stderr: "", exitCode: 0)
        }

        let tmux = TmuxClient(runner: runner, tmuxExecutable: "/opt/homebrew/bin/tmux")
        let pane = tmux.currentPane()

        XCTAssertEqual(pane?.paneId, "%12")
        XCTAssertEqual(pane?.paneTitle, "")
        XCTAssertEqual(pane?.windowName, "editor")
    }

    func testResolveTmuxExecutableUsesPreferredAbsolutePath() {
        let resolved = TmuxClient.resolveTmuxExecutable(
            runner: MockTmuxRunner { _, _ in CommandResult(stdout: "", stderr: "", exitCode: 1) },
            executableChecker: { $0 == "/opt/homebrew/bin/tmux" }
        )
        XCTAssertEqual(resolved, "/opt/homebrew/bin/tmux")
    }

    func testResolveTmuxExecutableFallsBackToWhich() {
        let resolved = TmuxClient.resolveTmuxExecutable(
            runner: MockTmuxRunner { executable, arguments in
                XCTAssertEqual(executable, "/usr/bin/which")
                XCTAssertEqual(arguments, ["tmux"])
                return CommandResult(stdout: "/custom/bin/tmux\n", stderr: "", exitCode: 0)
            },
            executableChecker: { $0 == "/custom/bin/tmux" }
        )
        XCTAssertEqual(resolved, "/custom/bin/tmux")
    }
}

private final class MockTmuxRunner: CommandRunning, @unchecked Sendable {
    private let handler: @Sendable (String, [String]) -> CommandResult

    init(handler: @escaping @Sendable (String, [String]) -> CommandResult) {
        self.handler = handler
    }

    func run(executable: String, arguments: [String], environment: [String: String]?) -> CommandResult {
        handler(executable, arguments)
    }
}
