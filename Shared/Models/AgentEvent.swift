import Foundation

/// An event detected from agent output.
public struct AgentEvent: Codable, Identifiable, Sendable {
    public let id: UUID
    public let agentId: UUID
    public let agentType: AgentType
    public let displayLabel: String
    public let eventType: EventType
    public let summary: String
    public let matchedRule: String
    public let priority: Priority
    public let shouldNotify: Bool
    public let dedupeKey: String
    public let timestamp: Date
    public let paneId: String
    public let windowId: String
    public let sessionName: String
    public var acknowledged: Bool
    public let contextLines: [String]?

    public init(
        id: UUID = UUID(),
        agentId: UUID,
        agentType: AgentType,
        displayLabel: String,
        eventType: EventType,
        summary: String,
        matchedRule: String,
        priority: Priority = .normal,
        shouldNotify: Bool = true,
        dedupeKey: String = "",
        timestamp: Date = Date(),
        paneId: String = "",
        windowId: String = "",
        sessionName: String = "",
        acknowledged: Bool = false,
        contextLines: [String]? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.agentType = agentType
        self.displayLabel = displayLabel
        self.eventType = eventType
        self.summary = Self.sanitize(summary)
        self.matchedRule = matchedRule
        self.priority = priority
        self.shouldNotify = shouldNotify
        if dedupeKey.isEmpty {
            self.dedupeKey = "\(agentId.uuidString)|\(eventType.rawValue)|\(displayLabel.lowercased())"
        } else {
            self.dedupeKey = dedupeKey
        }
        self.timestamp = timestamp
        self.paneId = paneId
        self.windowId = windowId
        self.sessionName = sessionName
        self.acknowledged = acknowledged
        self.contextLines = contextLines
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case agentId
        case agentType
        case displayLabel
        case eventType
        case summary
        case matchedRule
        case priority
        case shouldNotify
        case dedupeKey
        case timestamp
        case paneId
        case windowId
        case sessionName
        case acknowledged
        case contextLines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.agentId = try c.decode(UUID.self, forKey: .agentId)
        self.agentType = try c.decode(AgentType.self, forKey: .agentType)
        self.displayLabel = try c.decodeIfPresent(String.self, forKey: .displayLabel) ?? ""
        self.eventType = try c.decode(EventType.self, forKey: .eventType)
        self.summary = Self.sanitize(try c.decodeIfPresent(String.self, forKey: .summary) ?? "")
        self.matchedRule = try c.decodeIfPresent(String.self, forKey: .matchedRule) ?? ""
        self.priority = try c.decodeIfPresent(Priority.self, forKey: .priority) ?? .normal
        self.shouldNotify = try c.decodeIfPresent(Bool.self, forKey: .shouldNotify) ?? true
        self.dedupeKey = try c.decodeIfPresent(String.self, forKey: .dedupeKey)
            ?? "\(agentId.uuidString)|\(eventType.rawValue)|\(displayLabel.lowercased())"
        self.timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        self.paneId = try c.decodeIfPresent(String.self, forKey: .paneId) ?? ""
        self.windowId = try c.decodeIfPresent(String.self, forKey: .windowId) ?? ""
        self.sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName) ?? ""
        self.acknowledged = try c.decodeIfPresent(Bool.self, forKey: .acknowledged) ?? false
        self.contextLines = try c.decodeIfPresent([String].self, forKey: .contextLines)
    }

    /// Sanitize summary: trim whitespace, truncate to 200 chars.
    private static func sanitize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 200 { return trimmed }
        return String(trimmed.prefix(197)) + "..."
    }
}
