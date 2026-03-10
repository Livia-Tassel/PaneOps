import Foundation

/// Priority level for rules.
public enum Priority: String, Codable, Sendable, Comparable {
    case normal
    case high

    public static func < (lhs: Priority, rhs: Priority) -> Bool {
        let order: [Priority: Int] = [.high: 0, .normal: 1]
        return order[lhs, default: 1] < order[rhs, default: 1]
    }
}

/// A matching pattern within a rule.
public struct RulePattern: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID

    public enum Kind: String, Codable, Sendable, Equatable {
        case keyword
        case regex
    }

    public var kind: Kind
    public var value: String
    public var caseSensitive: Bool

    public init(id: UUID = UUID(), kind: Kind, value: String, caseSensitive: Bool = false) {
        self.id = id
        self.kind = kind
        self.value = value
        self.caseSensitive = caseSensitive
    }
}

/// A detection rule that maps output patterns to event types.
public struct Rule: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var agentType: AgentType?
    public var patterns: [RulePattern]
    public var eventType: EventType
    public var priority: Priority
    public var triggersNotification: Bool
    public var isBuiltin: Bool
    public var isEnabled: Bool
    public var cooldownSeconds: TimeInterval

    public var highPriority: Bool {
        get { priority == .high }
        set { priority = newValue ? .high : .normal }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        agentType: AgentType? = nil,
        patterns: [RulePattern],
        eventType: EventType,
        priority: Priority = .normal,
        triggersNotification: Bool = true,
        isBuiltin: Bool = false,
        isEnabled: Bool = true,
        cooldownSeconds: TimeInterval = 10
    ) {
        self.id = id
        self.name = name
        self.agentType = agentType
        self.patterns = patterns
        self.eventType = eventType
        self.priority = priority
        self.triggersNotification = triggersNotification
        self.isBuiltin = isBuiltin
        self.isEnabled = isEnabled
        self.cooldownSeconds = cooldownSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case agentType
        case patterns
        case eventType
        case priority
        case triggersNotification
        case isBuiltin
        case isEnabled
        case cooldownSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.agentType = try c.decodeIfPresent(AgentType.self, forKey: .agentType)
        self.patterns = try c.decode([RulePattern].self, forKey: .patterns)
        self.eventType = try c.decode(EventType.self, forKey: .eventType)
        self.priority = try c.decodeIfPresent(Priority.self, forKey: .priority) ?? .normal
        self.triggersNotification = try c.decodeIfPresent(Bool.self, forKey: .triggersNotification) ?? true
        self.isBuiltin = try c.decodeIfPresent(Bool.self, forKey: .isBuiltin) ?? false
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.cooldownSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .cooldownSeconds) ?? 10
    }
}
