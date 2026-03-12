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

        // ANSI-colored "Do you want to proceed? (y/n)"
        let data = "\u{1b}[1;33mDo you want to proceed? (y/n)\u{1b}[0m\n".data(using: .utf8)!
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
        processor.processData(" to proceed? (y/n)\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(events.value.first?.eventType, .permissionRequested)
    }

    func testPreservesSplitUTF8PromptAcrossChunks() {
        let expectation = XCTestExpectation(description: "Split UTF-8 prompt emits once")
        let events = LockedBox<[AgentEvent]>([])

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "utf8",
            rules: rules,
            stallTimeout: 999
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        let promptData = "❯".data(using: .utf8)!
        processor.processData(promptData.prefix(1))
        processor.processData(promptData.suffix(promptData.count - 1))

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
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

    func testDoesNotDuplicateBufferedPromptWhenNewlineArrives() {
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "prompt-dedupe",
            rules: rules,
            stallTimeout: 999
        ) { event in
            events.withLock { $0.append(event) }
        }

        processor.processData("❯".data(using: .utf8)!)
        processor.processData("\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
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

    func testSuppressesMetaRuleDescriptionFalsePositive() {
        let eventEmitted = LockedBox<Bool>(false)
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "meta",
            rules: rules,
            stallTimeout: 999
        ) { _ in
            eventEmitted.withLock { $0 = true }
        }

        let line = "- Claude: Do you want to proceed / Allow once / allow|proceed ... yes/no\n"
        processor.processData(line.data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertFalse(eventEmitted.value)
    }

    func testSuppressesInteractiveEventsBeforeFirstInputWhenEnabled() {
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "gate",
            rules: rules,
            stallTimeout: 999,
            suppressInteractiveUntilFirstInput: true
        ) { event in
            events.withLock { $0.append(event) }
        }

        processor.processData("❯\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(events.value.isEmpty)

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.4)
        processor.processData("❯\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(events.value.last?.eventType, .taskCompleted)
    }

    func testEnterOnlyInputUnlocksSuppressedInteractiveEvents() {
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "enter",
            rules: rules,
            stallTimeout: 999,
            suppressInteractiveUntilFirstInput: true
        ) { event in
            events.withLock { $0.append(event) }
        }

        processor.processData("❯\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(events.value.isEmpty)

        processor.noteUserInput("\n".data(using: .utf8)!)
        processor.processData("Hello.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.4)
        processor.processData("❯\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(events.value.last?.eventType, .taskCompleted)
    }

    func testDetectsCodexPromptAfterCarriageReturnRewrite() {
        let expectation = XCTestExpectation(description: "Codex prompt after carriage return emits once")
        let events = LockedBox<[AgentEvent]>([])

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .codex,
            displayLabel: "codex-cr",
            rules: rules,
            stallTimeout: 999
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.processData("Agent Sentinel is local-first.\r› ".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
    }

    func testDetectsCodexInlinePromptWithoutTrailingNewline() {
        let expectation = XCTestExpectation(description: "Codex inline prompt emits completion")
        let receivedEvent = LockedBox<AgentEvent?>(nil)

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .codex,
            displayLabel: "codex-inline",
            rules: rules,
            stallTimeout: 999
        ) { event in
            receivedEvent.withLock { $0 = event }
            expectation.fulfill()
        }

        processor.processData("› hello".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedEvent.value?.eventType, .taskCompleted)
    }

    func testDoesNotDuplicateCodexPromptWhenInputEchoExtendsPromptLine() {
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .codex,
            displayLabel: "codex-inline-dedupe",
            rules: rules,
            stallTimeout: 999
        ) { event in
            events.withLock { $0.append(event) }
        }

        processor.processData("› ".data(using: .utf8)!)
        processor.processData("hello".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
    }

    func testSuppressesClaudePromptEchoImmediatelyAfterUserInput() {
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-echo",
            rules: rules,
            stallTimeout: 999
        ) { event in
            events.withLock { $0.append(event) }
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("❯".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(events.value.isEmpty)

        processor.processData("Hello.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.4)
        processor.processData("❯".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
    }

    func testClaudePromptCompletionUsesLastAssistantLineVerbatim() {
        let expectation = XCTestExpectation(description: "Claude completion uses last assistant line")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-summary",
            rules: rules,
            stallTimeout: 999
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.4)
        processor.processData("❯\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
        XCTAssertEqual(events.value.first?.summary, "Hello.")
    }

    func testClaudePromptCompletionIgnoresSeparatorLineSummary() {
        let expectation = XCTestExpectation(description: "Claude completion ignores separator line summary")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-summary-separator",
            rules: rules,
            stallTimeout: 999
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Real answer line.\n".data(using: .utf8)!)
        processor.processData("────────────────────────────────────\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.4)
        processor.processData("❯\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
        XCTAssertEqual(events.value.first?.summary, "Real answer line.")
    }

    func testCodexQuietCompletionAfterAssistantOutputSilence() {
        let expectation = XCTestExpectation(description: "Codex emits quiet completion after assistant output")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .codex,
            displayLabel: "codex-quiet",
            rules: rules,
            stallTimeout: 999,
            codexCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            if event.eventType == .taskCompleted {
                expectation.fulfill()
            }
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("› hello".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(events.value.isEmpty)

        processor.processData("• Hello.\n".data(using: .utf8)!)
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
        XCTAssertEqual(events.value.first?.matchedRule, "Codex: Quiet completion")
        XCTAssertEqual(events.value.first?.summary, "Response completed: Hello.")
    }

    func testCodexChromeDoesNotTriggerQuietCompletionBeforeAssistantOutput() {
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .codex,
            displayLabel: "codex-chrome",
            rules: rules,
            stallTimeout: 999,
            codexCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("gpt-5.4 medium · 84% left · ~/Documents/Project/PaneOps · gpt-5.4 · PaneOps · master · 16% used · 5h 72%\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.25)

        XCTAssertTrue(events.value.isEmpty)
    }

    func testCodexQuietCompletionSuppressesLaterPromptDuplicate() {
        let expectation = XCTestExpectation(description: "Codex quiet completion emits once")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .codex,
            displayLabel: "codex-dedupe",
            rules: rules,
            stallTimeout: 999,
            codexCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            if event.eventType == .taskCompleted {
                expectation.fulfill()
            }
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("• Hello.\n".data(using: .utf8)!)
        wait(for: [expectation], timeout: 1.0)

        Thread.sleep(forTimeInterval: 0.3)
        processor.processData("› ".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.matchedRule, "Codex: Quiet completion")
    }

    func testStallDetectionOnlyRefiresAfterUserInput() {
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .codex,
            displayLabel: "stall-reset",
            rules: rules,
            stallTimeout: 0.15
        ) { event in
            events.withLock { $0.append(event) }
        }

        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .stalledOrWaiting)

        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(events.value.count, 1)

        processor.noteUserInput("retry\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.25)

        XCTAssertEqual(events.value.count, 2)
        XCTAssertEqual(events.value.last?.eventType, .stalledOrWaiting)
    }

    func testSuppressesRepeatedClaudePromptReadyWhileIdle() {
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-idle",
            rules: rules,
            stallTimeout: 999
        ) { event in
            events.withLock { $0.append(event) }
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.4)
        processor.processData("❯".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(events.value.count, 1)

        Thread.sleep(forTimeInterval: 1.3)
        processor.processData("❯".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(events.value.count, 1)
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
