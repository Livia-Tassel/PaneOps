import XCTest
@testable import SentinelShared

final class JumpServiceTests: XCTestCase {
    func testJumpSuccessRunsSessionAwareSequence() throws {
        let runner = MockRunner { executable, arguments in
            if executable == "/usr/bin/osascript" {
                return CommandResult(stdout: "", stderr: "", exitCode: 0)
            }
            return CommandResult(stdout: "%1", stderr: "", exitCode: 0)
        }

        let tmux = TmuxClient(runner: runner)
        let service = JumpService(tmux: tmux, runner: runner)

        XCTAssertNoThrow(
            try service.jump(to: JumpRequest(paneId: "%1", windowId: "@2", sessionName: "main"))
        )

        let flattened = runner.recorded.map { $0.joined(separator: " ") }.joined(separator: "\n")
        XCTAssertTrue(flattened.contains("tmux switch-client -t main"))
        XCTAssertTrue(flattened.contains("tmux select-pane -t %1"))
    }

    func testJumpFailsWhenPaneMissing() {
        let runner = MockRunner { executable, arguments in
            if executable == "/usr/bin/env", arguments.contains("display-message") {
                return CommandResult(stdout: "", stderr: "pane not found", exitCode: 1)
            }
            return CommandResult(stdout: "", stderr: "", exitCode: 0)
        }
        let tmux = TmuxClient(runner: runner)
        let service = JumpService(tmux: tmux, runner: runner)

        XCTAssertThrowsError(try service.jump(to: JumpRequest(paneId: "%404"))) { error in
            guard case JumpError.paneNotFound = error else {
                return XCTFail("Expected paneNotFound, got \(error)")
            }
        }
    }
}

private final class MockRunner: CommandRunning, @unchecked Sendable {
    private let handler: @Sendable (String, [String]) -> CommandResult
    private let lock = NSLock()
    private(set) var recorded: [[String]] = []

    init(handler: @escaping @Sendable (String, [String]) -> CommandResult) {
        self.handler = handler
    }

    func run(executable: String, arguments: [String], environment: [String: String]?) -> CommandResult {
        lock.lock()
        recorded.append([executable] + arguments)
        lock.unlock()
        return handler(executable, arguments)
    }
}
