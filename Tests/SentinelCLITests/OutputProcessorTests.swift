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

    func testPreservesSplitUTF8PromptAcrossChunksAfterAssistantOutput() {
        let expectation = XCTestExpectation(description: "Split UTF-8 prompt emits once after assistant output")
        let events = LockedBox<[AgentEvent]>([])

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "utf8",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.4)
        let promptData = "❯".data(using: .utf8)!
        processor.processData(promptData.prefix(1))
        processor.processData(promptData.suffix(promptData.count - 1))

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
    }

    func testDetectsPromptWithoutTrailingNewlineAfterAssistantOutput() {
        let expectation = XCTestExpectation(description: "Prompt event emitted from buffered candidate after assistant output")
        let receivedEvent = LockedBox<AgentEvent?>(nil)

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "prompt",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            receivedEvent.withLock { $0 = event }
            expectation.fulfill()
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.4)
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
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.4)
        processor.processData("❯".data(using: .utf8)!)
        processor.processData("\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.25)

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
            suppressInteractiveUntilFirstInput: true,
            promptCompletionQuietPeriod: 0.15
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
        Thread.sleep(forTimeInterval: 0.25)

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
            suppressInteractiveUntilFirstInput: true,
            promptCompletionQuietPeriod: 0.15
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
        Thread.sleep(forTimeInterval: 0.25)

        XCTAssertEqual(events.value.last?.eventType, .taskCompleted)
    }

    func testSuppressesCodexPromptAfterCarriageReturnRewriteWithoutAssistantOutput() {
        let events = LockedBox<[AgentEvent]>([])

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .codex,
            displayLabel: "codex-cr",
            rules: rules,
            stallTimeout: 999,
            suppressInteractiveUntilFirstInput: true,
            codexCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
        }

        processor.processData("Agent Sentinel is local-first.\r› ".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertTrue(events.value.isEmpty)
    }

    func testSuppressesCodexInlinePromptWithoutTrailingNewlineUntilAssistantOutput() {
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .codex,
            displayLabel: "codex-inline",
            rules: rules,
            stallTimeout: 999,
            codexCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("› hello".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertTrue(events.value.isEmpty)
    }

    func testIgnoresTerminalFocusReportBeforeCodexStartupPrompt() {
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .codex,
            displayLabel: "codex-focus",
            rules: rules,
            stallTimeout: 999,
            suppressInteractiveUntilFirstInput: true,
            codexCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
        }

        let focusIn = Data([0x1B, 0x5B, 0x49])
        XCTAssertFalse(processor.noteUserInput(focusIn))
        processor.processData("› ".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.25)

        XCTAssertTrue(events.value.isEmpty)
    }

    func testSuppressesClaudePromptEchoImmediatelyAfterUserInput() {
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-echo",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
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
        Thread.sleep(forTimeInterval: 0.25)

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
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
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

    func testClaudePromptCompletionStillFiresForFastResponses() {
        let expectation = XCTestExpectation(description: "Claude completion fires even when response is fast")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-fast",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.05)
        processor.processData("❯\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
        XCTAssertEqual(events.value.first?.summary, "Hello.")
    }

    func testClaudePromptCompletionSupportsChevronVariantPrompt() {
        let expectation = XCTestExpectation(description: "Claude completion supports › prompt")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-chevron",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello from chevron prompt.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.3)
        processor.processData("›\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.2)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
        XCTAssertEqual(events.value.first?.summary, "Hello from chevron prompt.")
    }

    func testClaudePromptCompletionSupportsHeavyChevronVariantPrompt() {
        let expectation = XCTestExpectation(description: "Claude completion supports ❱ prompt")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-heavy-chevron",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello from heavy chevron prompt.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.3)
        processor.processData("❱\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.2)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
        XCTAssertEqual(events.value.first?.summary, "Hello from heavy chevron prompt.")
    }

    func testClaudePromptCompletionSupportsPromptWithCursorGlyph() {
        let expectation = XCTestExpectation(description: "Claude completion supports prompt with cursor glyph")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-cursor-glyph",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello from cursor prompt.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.3)
        processor.processData("❯ █".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.2)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
        XCTAssertEqual(events.value.first?.summary, "Hello from cursor prompt.")
    }

    func testClaudePromptCompletionSupportsInlinePromptSuggestionWithNBSP() {
        let expectation = XCTestExpectation(description: "Claude completion supports inline suggestion prompt with NBSP")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-inline-suggestion",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello from inline suggestion prompt.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.3)
        processor.processData("❯\u{00A0}Try \"refactor RunCommand.swift\"".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.2)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
        XCTAssertEqual(events.value.first?.summary, "Hello from inline suggestion prompt.")
    }

    func testClaudePromptCompletionSupportsEmbeddedPromptOnSingleRenderedLine() {
        let expectation = XCTestExpectation(description: "Claude completion supports embedded prompt on single rendered line")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-embedded-prompt",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("● Hello! How can I help you with PaneOps today? ❯".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.6)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
        XCTAssertEqual(events.value.first?.summary, "● Hello! How can I help you with PaneOps today?")
    }

    func testClaudePromptCompletionIsNotCancelledByPostPromptStatusLine() {
        let expectation = XCTestExpectation(description: "Claude completion survives post-prompt status churn")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-status-churn",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello from status churn.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.3)
        processor.processData("❯\u{00A0}Try \"refactor RunCommand.swift\"\n".data(using: .utf8)!)
        processor.processData("tassel | .../Documents/Project/PaneOps | master* | Sonnet 4.6 | ♥ 19:06\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.2)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
        XCTAssertEqual(events.value.first?.summary, "Hello from status churn.")
    }

    func testClaudePromptCompletionDetectsPromptTailFromLongBufferedLine() {
        let expectation = XCTestExpectation(description: "Claude completion matches long buffered separator+prompt tail")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-long-buffer",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello from long buffer prompt.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.3)
        let longTail = String(repeating: "─", count: 140) + "❯"
        processor.processData(longTail.data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.2)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.eventType, .taskCompleted)
        XCTAssertEqual(events.value.first?.summary, "Hello from long buffer prompt.")
    }

    func testClaudeThinkingStatusDoesNotTriggerCompletionBeforeRealAnswer() {
        let expectation = XCTestExpectation(description: "Claude completion waits for real answer after thinking status")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-status",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            if event.eventType == .taskCompleted {
                expectation.fulfill()
            }
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("✽ Stewing…\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.05)
        processor.processData("❯\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertTrue(events.value.isEmpty)

        processor.processData("Hello.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.05)
        processor.processData("❯\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(events.value.count, 1)
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
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
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

    func testClaudePromptCompletionWaitsForQuietAfterPrompt() {
        let expectation = XCTestExpectation(description: "Claude completion waits for quiet after prompt")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-quiet-prompt",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            expectation.fulfill()
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("First line.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.4)
        processor.processData("❯".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.05)
        processor.processData("Still working.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(events.value.isEmpty)

        processor.processData("❯".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.summary, "Still working.")
    }

    func testClaudePromptCompletionFallsBackWhenSummaryUnavailable() {
        let expectation = XCTestExpectation(description: "Claude completion falls back without reliable summary")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-fallback",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            if event.eventType == .taskCompleted {
                expectation.fulfill()
            }
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("✳ Stewing (33s · ↓302 tokens)\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.45)
        processor.processData("❯\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.summary, "Response completed")
    }

    func testClaudeStatusLineWithTokenSuffixDoesNotReplaceAnswerSummary() {
        let expectation = XCTestExpectation(description: "Claude status line with tokens is ignored as summary")
        let events = LockedBox<[AgentEvent]>([])
        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "claude-status-token",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
            if event.eventType == .taskCompleted {
                expectation.fulfill()
            }
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("✳ Stewing… (33s · ↓302 tokens)\n".data(using: .utf8)!)
        processor.processData("Actual answer line.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.3)
        processor.processData("❯\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 1.2)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.summary, "Actual answer line.")
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
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15
        ) { event in
            events.withLock { $0.append(event) }
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.4)
        processor.processData("❯".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(events.value.count, 1)

        Thread.sleep(forTimeInterval: 1.3)
        processor.processData("❯".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.25)

        XCTAssertEqual(events.value.count, 1)
    }
    func testPermissionEventIncludesContextLines() {
        let expectation = XCTestExpectation(description: "Permission event with context")
        let receivedEvent = LockedBox<AgentEvent?>(nil)

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "ctx-test",
            rules: rules,
            stallTimeout: 999
        ) { event in
            receivedEvent.withLock { $0 = event }
            expectation.fulfill()
        }

        processor.processData("Building project...\nRunning tests...\n".data(using: .utf8)!)
        processor.processData("Do you want to proceed? (y/n)\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertNotNil(receivedEvent.value?.contextLines)
        XCTAssertTrue(receivedEvent.value!.contextLines!.count >= 2)
    }

    func testContextLinesRingBufferCapsAtFiveLines() {
        let expectation = XCTestExpectation(description: "Context caps at 5")
        let receivedEvent = LockedBox<AgentEvent?>(nil)

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "ctx-cap",
            rules: rules,
            stallTimeout: 999
        ) { event in
            if event.eventType == .permissionRequested {
                receivedEvent.withLock { $0 = event }
                expectation.fulfill()
            }
        }

        for i in 1...10 {
            processor.processData("Line \(i) of output\n".data(using: .utf8)!)
        }
        processor.processData("Do you want to proceed? (y/n)\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertNotNil(receivedEvent.value?.contextLines)
        XCTAssertEqual(receivedEvent.value!.contextLines!.count, 5)
    }

    func testContextLinesNilForErrorEvents() {
        let expectation = XCTestExpectation(description: "Error event no context")
        let receivedEvent = LockedBox<AgentEvent?>(nil)

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .custom,
            displayLabel: "ctx-err",
            rules: rules,
            stallTimeout: 999
        ) { event in
            receivedEvent.withLock { $0 = event }
            expectation.fulfill()
        }

        processor.processData("Some output\nfatal: repository not found\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertNil(receivedEvent.value?.contextLines)
    }

    func testOutputSilenceCompletionFiresWhenNoPromptDetected() {
        let expectation = XCTestExpectation(description: "Silence completion fires")
        let events = LockedBox<[AgentEvent]>([])

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "silence",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15,
            outputSilenceCompletionSeconds: 0.3
        ) { event in
            events.withLock { $0.append(event) }
            if event.matchedRule == "output-silence-completion" {
                expectation.fulfill()
            }
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        // Simulate output that doesn't end with a prompt symbol
        processor.processData("Here is my answer to your question.\n".data(using: .utf8)!)
        processor.processData("The result is 42.\n".data(using: .utf8)!)

        wait(for: [expectation], timeout: 2.0)
        let silenceEvents = events.value.filter { $0.matchedRule == "output-silence-completion" }
        XCTAssertEqual(silenceEvents.count, 1)
        XCTAssertEqual(silenceEvents.first?.eventType, .taskCompleted)
    }

    func testOutputSilenceCompletionDoesNotFireWhenPromptDetected() {
        let events = LockedBox<[AgentEvent]>([])

        let rules = RuleEngine.effectiveRules(config: AppConfig())
        let processor = OutputProcessor(
            agentId: UUID(),
            agentType: .claude,
            displayLabel: "silence-suppressed",
            rules: rules,
            stallTimeout: 999,
            promptCompletionQuietPeriod: 0.15,
            outputSilenceCompletionSeconds: 0.5
        ) { event in
            events.withLock { $0.append(event) }
        }

        processor.noteUserInput("hello\n".data(using: .utf8)!)
        processor.processData("Hello.\n".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.3)
        processor.processData("❯\n".data(using: .utf8)!)
        // Wait past the silence timeout
        Thread.sleep(forTimeInterval: 0.7)

        let silenceEvents = events.value.filter { $0.matchedRule == "output-silence-completion" }
        XCTAssertEqual(silenceEvents.count, 0, "Silence completion should not fire when prompt was detected")
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
