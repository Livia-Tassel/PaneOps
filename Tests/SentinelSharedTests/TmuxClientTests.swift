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
    func testSendKeysCallsTmuxWithCorrectArguments() {
        let calls = LockedCalls()
        let runner = MockTmuxRunner { _, arguments in
            calls.append(arguments)
            return CommandResult(stdout: "", stderr: "", exitCode: 0)
        }
        let tmux = TmuxClient(runner: runner, tmuxExecutable: "/opt/homebrew/bin/tmux")
        let result = tmux.sendKeys(to: "%5", text: "y")

        XCTAssertTrue(result)
        let recorded = calls.all
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded[0], ["send-keys", "-t", "%5", "-l", "--", "y"])
        XCTAssertEqual(recorded[1], ["send-keys", "-t", "%5", "Enter"])
    }

    func testSendKeysReturnsFalseForEmptyPaneId() {
        let runner = MockTmuxRunner { _, _ in
            CommandResult(stdout: "", stderr: "", exitCode: 0)
        }
        let tmux = TmuxClient(runner: runner, tmuxExecutable: "/opt/homebrew/bin/tmux")
        XCTAssertFalse(tmux.sendKeys(to: "", text: "y"))
    }

    func testSendKeysWithoutEnterSendsOnlyText() {
        let calls = LockedCalls()
        let runner = MockTmuxRunner { _, arguments in
            calls.append(arguments)
            return CommandResult(stdout: "", stderr: "", exitCode: 0)
        }
        let tmux = TmuxClient(runner: runner, tmuxExecutable: "/opt/homebrew/bin/tmux")
        let result = tmux.sendKeys(to: "%3", text: "hello", enterAfter: false)

        XCTAssertTrue(result)
        let recorded = calls.all
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0], ["send-keys", "-t", "%3", "-l", "--", "hello"])
    }

    func testSendKeysReturnsFalseOnTmuxFailure() {
        let runner = MockTmuxRunner { _, _ in
            CommandResult(stdout: "", stderr: "pane not found", exitCode: 1)
        }
        let tmux = TmuxClient(runner: runner, tmuxExecutable: "/opt/homebrew/bin/tmux")
        XCTAssertFalse(tmux.sendKeys(to: "%99", text: "y"))
    }
}

private final class LockedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []

    func append(_ args: [String]) {
        lock.withLock { _calls.append(args) }
    }

    var all: [[String]] {
        lock.withLock { _calls }
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
