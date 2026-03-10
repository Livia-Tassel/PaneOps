import Foundation

/// Built-in detection rules for known agent types.
public enum BuiltinRules {

    /// All built-in rules with deterministic UUIDs (for stable disabling).
    public static let all: [Rule] = claude + codex + gemini + universal

    // MARK: - Claude Code

    public static let claude: [Rule] = [
        // The ❯ prompt on its own line means Claude finished and is waiting for input
        Rule(
            id: UUID(uuidString: "00000001-0001-0001-0001-000000000006")!,
            name: "Claude: Prompt ready (❯)",
            agentType: .claude,
            patterns: [
                RulePattern(kind: .regex, value: "^❯\\s*$"),
                RulePattern(kind: .regex, value: "^\\s*❯\\s*$"),
            ],
            eventType: .inputRequested,
            priority: .normal,
            isBuiltin: true,
            cooldownSeconds: 5
        ),
        Rule(
            id: UUID(uuidString: "00000001-0001-0001-0001-000000000001")!,
            name: "Claude: Permission prompt",
            agentType: .claude,
            patterns: [
                RulePattern(kind: .keyword, value: "Do you want to proceed"),
                RulePattern(kind: .keyword, value: "Allow once"),
                RulePattern(kind: .keyword, value: "Allow always"),
                RulePattern(kind: .keyword, value: "want to allow"),
            ],
            eventType: .permissionRequested,
            priority: .high,
            isBuiltin: true,
            cooldownSeconds: 10
        ),
        Rule(
            id: UUID(uuidString: "00000001-0001-0001-0001-000000000004")!,
            name: "Claude: Task completed",
            agentType: .claude,
            patterns: [
                RulePattern(kind: .keyword, value: "Task completed"),
                RulePattern(kind: .keyword, value: "Completed in"),
            ],
            eventType: .taskCompleted,
            priority: .normal,
            isBuiltin: true,
            cooldownSeconds: 5
        ),
        Rule(
            id: UUID(uuidString: "00000001-0001-0001-0001-000000000005")!,
            name: "Claude: Error",
            agentType: .claude,
            patterns: [
                RulePattern(kind: .keyword, value: "Error:"),
                RulePattern(kind: .keyword, value: "FAILED"),
            ],
            eventType: .errorDetected,
            priority: .normal,
            isBuiltin: true,
            cooldownSeconds: 15
        ),
    ]

    // MARK: - Codex

    public static let codex: [Rule] = [
        Rule(
            id: UUID(uuidString: "00000002-0002-0002-0002-000000000003")!,
            name: "Codex: Input prompt",
            agentType: .codex,
            patterns: [
                RulePattern(kind: .regex, value: "(?i)^\\s*>\\s*$"),
                RulePattern(kind: .keyword, value: "Press Enter to continue"),
            ],
            eventType: .inputRequested,
            priority: .normal,
            isBuiltin: true,
            cooldownSeconds: 5
        ),
        Rule(
            id: UUID(uuidString: "00000002-0002-0002-0002-000000000001")!,
            name: "Codex: Approve changes",
            agentType: .codex,
            patterns: [RulePattern(kind: .keyword, value: "approve changes")],
            eventType: .permissionRequested,
            priority: .high,
            isBuiltin: true,
            cooldownSeconds: 10
        ),
        Rule(
            id: UUID(uuidString: "00000002-0002-0002-0002-000000000002")!,
            name: "Codex: Completed",
            agentType: .codex,
            patterns: [RulePattern(kind: .keyword, value: "completed successfully")],
            eventType: .taskCompleted,
            priority: .normal,
            isBuiltin: true,
            cooldownSeconds: 5
        ),
    ]

    // MARK: - Gemini

    public static let gemini: [Rule] = [
        Rule(
            id: UUID(uuidString: "00000003-0003-0003-0003-000000000003")!,
            name: "Gemini: Input prompt",
            agentType: .gemini,
            patterns: [
                RulePattern(kind: .keyword, value: "Your input"),
                RulePattern(kind: .keyword, value: "Choose an option"),
            ],
            eventType: .inputRequested,
            priority: .normal,
            isBuiltin: true,
            cooldownSeconds: 5
        ),
        Rule(
            id: UUID(uuidString: "00000003-0003-0003-0003-000000000001")!,
            name: "Gemini: Confirm action",
            agentType: .gemini,
            patterns: [
                RulePattern(kind: .keyword, value: "Confirm"),
                RulePattern(kind: .keyword, value: "confirm action"),
            ],
            eventType: .permissionRequested,
            priority: .high,
            isBuiltin: true,
            cooldownSeconds: 10
        ),
        Rule(
            id: UUID(uuidString: "00000003-0003-0003-0003-000000000002")!,
            name: "Gemini: Done/Finished",
            agentType: .gemini,
            patterns: [
                RulePattern(kind: .keyword, value: "Done"),
                RulePattern(kind: .keyword, value: "Finished"),
            ],
            eventType: .taskCompleted,
            priority: .normal,
            isBuiltin: true,
            cooldownSeconds: 5
        ),
    ]

    // MARK: - Universal

    public static let universal: [Rule] = [
        Rule(
            id: UUID(uuidString: "00000004-0004-0004-0004-000000000003")!,
            name: "Universal: Awaiting input",
            agentType: nil,
            patterns: [
                RulePattern(kind: .regex, value: "(?i)waiting for (user )?input"),
                RulePattern(kind: .regex, value: "(?i)press enter to continue"),
            ],
            eventType: .inputRequested,
            priority: .normal,
            isBuiltin: true,
            cooldownSeconds: 8
        ),
        Rule(
            id: UUID(uuidString: "00000004-0004-0004-0004-000000000001")!,
            name: "Universal: Error prefix",
            agentType: nil,
            patterns: [RulePattern(kind: .regex, value: "(?i)^error[: ]")],
            eventType: .errorDetected,
            priority: .normal,
            isBuiltin: true,
            cooldownSeconds: 15
        ),
        Rule(
            id: UUID(uuidString: "00000004-0004-0004-0004-000000000002")!,
            name: "Universal: Fatal/panic/traceback",
            agentType: nil,
            patterns: [RulePattern(kind: .regex, value: "(?i)fatal|panic|traceback|segfault")],
            eventType: .errorDetected,
            priority: .high,
            isBuiltin: true,
            cooldownSeconds: 15
        ),
    ]
}
