import Foundation

/// Matches terminal output lines against detection rules.
public final class RuleEngine: @unchecked Sendable {

    /// Result of a successful match.
    public struct MatchResult: Sendable {
        public let rule: Rule
        public let matchedText: String
    }

    private var rules: [Rule]
    private var regexCache: [RegexCacheKey: NSRegularExpression] = [:]
    private var cooldowns: [CooldownKey: Date] = [:]
    private let lock = NSLock()

    private struct CooldownKey: Hashable {
        let agentId: UUID
        let ruleId: UUID
    }

    private struct RegexCacheKey: Hashable {
        let ruleId: UUID
        let patternValue: String
        let caseSensitive: Bool
    }

    public init(rules: [Rule] = []) {
        self.rules = rules
        rebuildCache()
    }

    /// Update the rule set (e.g., after config change).
    public func updateRules(_ newRules: [Rule]) {
        lock.lock()
        defer { lock.unlock() }
        self.rules = newRules
        rebuildCache()
    }

    /// Build the effective rule set: builtins (minus disabled) + custom.
    public static func effectiveRules(config: AppConfig) -> [Rule] {
        let builtins = BuiltinRules.all.filter { !config.disabledBuiltinRuleIds.contains($0.id) }
        let custom = config.customRules.filter(\.isEnabled)
        // Sort by priority (high first)
        return (builtins + custom).sorted { $0.priority < $1.priority }
    }

    /// Match a line against all enabled rules for the given agent type.
    /// Returns the first (highest-priority) match, respecting cooldowns.
    public func match(line: String, agentType: AgentType, agentId: UUID) -> MatchResult? {
        lock.lock()
        let currentRules = rules
        lock.unlock()

        let now = Date()

        for rule in currentRules where rule.isEnabled {
            // Skip rules targeting a different agent type
            if let ruleAgent = rule.agentType, ruleAgent != agentType {
                continue
            }

            // Check cooldown
            let key = CooldownKey(agentId: agentId, ruleId: rule.id)
            lock.lock()
            let lastFired = cooldowns[key]
            lock.unlock()

            if let last = lastFired, now.timeIntervalSince(last) < rule.cooldownSeconds {
                continue
            }

            // Try each pattern (OR logic)
            for pattern in rule.patterns {
                if matches(pattern: pattern, line: line, rule: rule) {
                    // Record cooldown
                    lock.lock()
                    cooldowns[key] = now
                    lock.unlock()

                    return MatchResult(rule: rule, matchedText: line)
                }
            }
        }

        return nil
    }

    /// Clear all cooldowns (e.g., for testing).
    public func clearCooldowns() {
        lock.lock()
        cooldowns.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private func matches(pattern: RulePattern, line: String, rule: Rule) -> Bool {
        switch pattern.kind {
        case .keyword:
            let options: String.CompareOptions = pattern.caseSensitive ? [] : [.caseInsensitive]
            return line.range(of: pattern.value, options: options) != nil

        case .regex:
            let regex = cachedRegex(for: pattern, ruleId: rule.id)
            guard let regex else { return false }
            let range = NSRange(line.startIndex..., in: line)
            return regex.firstMatch(in: line, range: range) != nil
        }
    }

    private func cachedRegex(for pattern: RulePattern, ruleId: UUID) -> NSRegularExpression? {
        let cacheId = RegexCacheKey(
            ruleId: ruleId,
            patternValue: pattern.value,
            caseSensitive: pattern.caseSensitive
        )

        lock.lock()
        if let cached = regexCache[cacheId] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var options: NSRegularExpression.Options = []
        if !pattern.caseSensitive {
            options.insert(.caseInsensitive)
        }
        guard let regex = try? NSRegularExpression(pattern: pattern.value, options: options) else {
            SentinelLogger.rules.warning("Invalid regex: \(pattern.value)")
            return nil
        }

        lock.lock()
        regexCache[cacheId] = regex
        lock.unlock()
        return regex
    }

    private func rebuildCache() {
        regexCache.removeAll()
    }
}
