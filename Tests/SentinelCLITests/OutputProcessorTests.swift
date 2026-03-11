import XCTest
@testable import SentinelShared
@testable import SentinelCLI

final class OutputProcessorTests: XCTestCase {
    func testDetectsPermissionRequest() {
        let expectation = XCTestExpectation(description: "Event emitted")
        let receivedEvent = LockedBox<AgentEvent?>(nil)

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "test",
            rules: rules,
            stallTimeout: 999
        ) { event in
            receivedEvent.withLock { $0 = event }
            expectation.fulfill()
        }

        let data = "Do you want to proceed? (y/n)\n".data(using: .utf8)!
        processor.processData(data)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertNotNil(receivedEvent.value)
        XCTAssertEqual(receivedEvent.value?.eventType, .permissionRequested)
    }

    func testDetectsError() {
        let expectation = XCTestExpectation(description: "Error event")
        let receivedEvent = LockedBox<AgentEvent?>(nil)

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .custom,
            displayLabel: "test",
            rules: rules,
            stallTimeout: 999
        ) { event in
            receivedEvent.withLock { $0 = event }
            expectation.fulfill()
        }

        let data = "fatal: repository not found\n".data(using: .utf8)!
        processor.processData(data)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertNotNil(receivedEvent.value)
        XCTAssertEqual(receivedEvent.value?.eventType, .errorDetected)
    }

    func testStripsANSIBeforeMatching() {
        let expectation = XCTestExpectation(description: "Event after ANSI strip")
        let receivedEvent = LockedBox<AgentEvent?>(nil)

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "test",
            rules: rules,
            stallTimeout: 999
        ) { event in
            receivedEvent.withLock { $0 = event }
            expectation.fulfill()
        }

        // ANSI-colored "Do you want to proceed"
        let data = "\u{1b}[1;33mDo you want to proceed?\u{1b}[0m\n".data(using: .utf8)!
        processor.processData(data)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertNotNil(receivedEvent.value)
        XCTAssertEqual(receivedEvent.value?.eventType, .permissionRequested)
    }

    func testNoMatchForIrrelevantOutput() {
        let eventEmitted = LockedBox<Bool>(false)

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "test",
            rules: rules,
            stallTimeout: 999
        ) { _ in
            eventEmitted.withLock { $0 = true }
        }

        let data = "Compiling module...\nDone compiling.\n".data(using: .utf8)!
        processor.processData(data)

        // Brief wait to ensure no event fires
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(eventEmitted.value)
    }

    func testSummarySanitization() {
        let longText = String(repeating: "a", count: 300)
        let event = AgentEvent(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "test",
            eventType: .errorDetected,
            summary: longText,
            matchedRule: "test"
        )
        XCTAssertTrue(event.summary.count <= 200)
        XCTAssertTrue(event.summary.hasSuffix("..."))
    }

    func testSuppressesHighFrequencyDuplicateLines() {
        let events = LockedBox<[AgentEvent]>([])

        let rules = [
            Rule(
                name: "duplicate",
                patterns: [RulePattern(kind: .keyword, value: "need input")],
                eventType: .inputRequested,
                cooldownSeconds: 0
            ),
        ]
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .custom,
            displayLabel: "dup",
            rules: rules,
            stallTimeout: 999
        ) { event in
            events.withLock { $0.append(event) }
        }

        processor.processData("need input\n".data(using: .utf8)!)
        processor.processData("need input\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(events.value.count, 1)
    }

    func testPartialLineBuffering() {
        let expectation = XCTestExpectation(description: "Event emitted after line completion")
        let events = LockedBox<[AgentEvent]>([])

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "partial",
            rules: rules,
            stallTimeout: 999
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.processData("Do you want".data(using: .utf8)!)
        processor.processData(" to proceed?\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(events.value.first?.eventType, .permissionRequested)
    }

    func testDetectsPromptWithoutTrailingNewline() {
        let expectation = XCTestExpectation(description: "Prompt event emitted from buffered candidate")
        let receivedEvent = LockedBox<AgentEvent?>(nil)

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "prompt",
            rules: rules,
            stallTimeout: 999
        ) { event in
            receivedEvent.withLock { $0 = event }
            expectation.fulfill()
        }

        processor.processData("❯".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedEvent.value?.eventType, .taskCompleted)
    }

    func testRateLimitDoesNotDropCriticalLines() {
        let expectation = XCTestExpectation(description: "Permission event should still be detected")
        let receivedEvent = LockedBox<AgentEvent?>(nil)

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "rate",
            rules: rules,
            stallTimeout: 999,
            rateLimitLinesPerSec: 1
        ) { event in
            if event.eventType == .permissionRequested {
                receivedEvent.withLock { $0 = event }
                expectation.fulfill()
            }
        }

        processor.processData(
            """
            Do you want to proceed? (y/n)
            noise line 1
            noise line 2
            """.data(using: .utf8)!
        )

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedEvent.value?.eventType, .permissionRequested)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        self.storage = initial
    }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withLock(_ mutate: (inout T) -> Void) {
        lock.lock()
        mutate(&storage)
        lock.unlock()
    }
}
