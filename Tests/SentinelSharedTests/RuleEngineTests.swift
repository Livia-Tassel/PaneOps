import XCTest
@testable import SentinelShared

final class RuleEngineTests: XCTestCase {
    func testKeywordMatch() {
        let rules = [
            Rule(
                name: "Test permission",
                patterns: [RulePattern(kind: .keyword, value: "Do you want to proceed")],
                eventType: .permissionRequested,
                priority: .high
            )
        ]
        let engine = RuleEngine(rules: rules)
        let agentId = UUID()

        let match = engine.match(line: "Do you want to proceed? (y/n)", agentType: .claude, agentId: agentId)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.rule.eventType, .permissionRequested)
    }

    func testKeywordCaseInsensitive() {
        let rules = [
            Rule(
                name: "Error",
                patterns: [RulePattern(kind: .keyword, value: "error:")],
                eventType: .errorDetected
            )
        ]
        let engine = RuleEngine(rules: rules)
        let agentId = UUID()

        let match = engine.match(line: "ERROR: something went wrong", agentType: .custom, agentId: agentId)
        XCTAssertNotNil(match)
    }

    func testRegexMatch() {
        let rules = [
            Rule(
                name: "Fatal regex",
                patterns: [RulePattern(kind: .regex, value: "(?i)fatal|panic|traceback")],
                eventType: .errorDetected,
                priority: .high,
                cooldownSeconds: 0
            )
        ]
        let engine = RuleEngine(rules: rules)
        let agentId = UUID()

        XCTAssertNotNil(engine.match(line: "FATAL: out of memory", agentType: .custom, agentId: agentId))
        XCTAssertNotNil(engine.match(line: "panic: runtime error", agentType: .custom, agentId: agentId))
        XCTAssertNotNil(engine.match(line: "Traceback (most recent call last):", agentType: .custom, agentId: agentId))
    }

    func testNoMatch() {
        let rules = [
            Rule(
                name: "Test",
                patterns: [RulePattern(kind: .keyword, value: "specific phrase")],
                eventType: .taskCompleted
            )
        ]
        let engine = RuleEngine(rules: rules)

        let match = engine.match(line: "nothing relevant here", agentType: .custom, agentId: UUID())
        XCTAssertNil(match)
    }

    func testCooldown() {
        let rules = [
            Rule(
                name: "Test",
                patterns: [RulePattern(kind: .keyword, value: "error")],
                eventType: .errorDetected,
                cooldownSeconds: 10
            )
        ]
        let engine = RuleEngine(rules: rules)
        let agentId = UUID()

        // First match should succeed
        XCTAssertNotNil(engine.match(line: "error happened", agentType: .custom, agentId: agentId))
        // Second match within cooldown should be suppressed
        XCTAssertNil(engine.match(line: "error again", agentType: .custom, agentId: agentId))
    }

    func testAgentTypeFiltering() {
        let rules = [
            Rule(
                name: "Claude only",
                agentType: .claude,
                patterns: [RulePattern(kind: .keyword, value: "test")],
                eventType: .taskCompleted
            )
        ]
        let engine = RuleEngine(rules: rules)
        let agentId = UUID()

        // Should match for claude
        XCTAssertNotNil(engine.match(line: "test output", agentType: .claude, agentId: agentId))
        // Should NOT match for codex
        XCTAssertNil(engine.match(line: "test output", agentType: .codex, agentId: agentId))
    }

    func testPriorityOrdering() {
        let rules = [
            Rule(
                name: "Normal",
                patterns: [RulePattern(kind: .keyword, value: "error")],
                eventType: .errorDetected,
                priority: .normal
            ),
            Rule(
                name: "High",
                patterns: [RulePattern(kind: .keyword, value: "error")],
                eventType: .permissionRequested,
                priority: .high
            ),
        ]
        // High priority should come first when sorted
        let sorted = rules.sorted { $0.priority < $1.priority }
        XCTAssertEqual(sorted[0].name, "High")
    }

    func testBuiltinRulesNotEmpty() {
        XCTAssertFalse(BuiltinRules.all.isEmpty)
        XCTAssertFalse(BuiltinRules.claude.isEmpty)
        XCTAssertFalse(BuiltinRules.universal.isEmpty)
    }

    func testEffectiveRulesWithDisabled() {
        var config = AppConfig()
        let firstClaudeId = BuiltinRules.claude[0].id
        config.disabledBuiltinRuleIds = [firstClaudeId]

        let effective = RuleEngine.effectiveRules(config: config)
        XCTAssertFalse(effective.contains { $0.id == firstClaudeId })
    }

    func testClaudePermissionRuleDoesNotMatchPermissionsHelpTip() {
        let engine = RuleEngine(rules: RuleEngine.effectiveRules(config: AppConfig()))
        let agentId = UUID()
        let line = "Tip: Use /permissions to pre-approve and pre-deny bash, edit, and MCP tools"

        let match = engine.match(line: line, agentType: .claude, agentId: agentId)
        XCTAssertTrue(match == nil || match?.rule.eventType != .permissionRequested)
    }

    func testClaudePermissionRequiresYesNoSignal() {
        let engine = RuleEngine(rules: RuleEngine.effectiveRules(config: AppConfig()))
        let agentId = UUID()

        let falsePositiveLine = "Approval required before continuing."
        let validPromptLine = "Do you want to proceed? (yes/no)"

        let first = engine.match(line: falsePositiveLine, agentType: .claude, agentId: agentId)
        XCTAssertTrue(first == nil || first?.rule.eventType != .permissionRequested)

        let second = engine.match(line: validPromptLine, agentType: .claude, agentId: agentId)
        XCTAssertEqual(second?.rule.eventType, .permissionRequested)
    }

    func testUniversalInputRuleDoesNotMatchNarrativeSentence() {
        let engine = RuleEngine(rules: RuleEngine.effectiveRules(config: AppConfig()))
        let agentId = UUID()
        let line = "rules to detect events (e.g., agent waiting for input, errors, task completion)"

        let match = engine.match(line: line, agentType: .codex, agentId: agentId)
        XCTAssertTrue(match == nil || match?.rule.eventType != .inputRequested)
    }
}
