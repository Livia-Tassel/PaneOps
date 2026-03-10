import Foundation

/// Status of a monitored agent.
public enum AgentStatus: String, Codable, Sendable {
    case running
    case waiting
    case completed
    case errored
    case stalled
}

/// A monitored agent instance, representing one CLI wrapper process.
public struct AgentInstance: Codable, Identifiable, Sendable {
    public let id: UUID
    public let agentType: AgentType
    public let sessionName: String
    public let sessionId: String
    public let windowId: String
    public let paneId: String
    public let windowName: String
    public let paneTitle: String
    public let cwd: String
    public let taskLabel: String?
    public let pid: Int32
    public let startedAt: Date
    public var lastActiveAt: Date
    public var status: AgentStatus

    public init(
        id: UUID = UUID(),
        agentType: AgentType,
        sessionName: String = "",
        sessionId: String = "",
        windowId: String = "",
        paneId: String = "",
        windowName: String = "",
        paneTitle: String = "",
        cwd: String = "",
        taskLabel: String? = nil,
        pid: Int32 = 0,
        startedAt: Date = Date(),
        lastActiveAt: Date = Date(),
        status: AgentStatus = .running
    ) {
        self.id = id
        self.agentType = agentType
        self.sessionName = sessionName
        self.sessionId = sessionId
        self.windowId = windowId
        self.paneId = paneId
        self.windowName = windowName
        self.paneTitle = paneTitle
        self.cwd = cwd
        self.taskLabel = taskLabel
        self.pid = pid
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case agentType
        case sessionName
        case sessionId
        case windowId
        case paneId
        case windowName
        case paneTitle
        case cwd
        case taskLabel
        case pid
        case startedAt
        case lastActiveAt
        case status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.agentType = try c.decode(AgentType.self, forKey: .agentType)
        self.sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName) ?? ""
        self.sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        self.windowId = try c.decodeIfPresent(String.self, forKey: .windowId) ?? ""
        self.paneId = try c.decodeIfPresent(String.self, forKey: .paneId) ?? ""
        self.windowName = try c.decodeIfPresent(String.self, forKey: .windowName) ?? ""
        self.paneTitle = try c.decodeIfPresent(String.self, forKey: .paneTitle) ?? ""
        self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        self.taskLabel = try c.decodeIfPresent(String.self, forKey: .taskLabel)
        self.pid = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        self.startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        self.lastActiveAt = try c.decodeIfPresent(Date.self, forKey: .lastActiveAt) ?? self.startedAt
        self.status = try c.decodeIfPresent(AgentStatus.self, forKey: .status) ?? .running
    }

    /// Display label with priority: taskLabel > windowName > cwd basename > paneId
    public var displayLabel: String {
        if let label = taskLabel, !label.isEmpty { return label }
        if !windowName.isEmpty { return windowName }
        if !cwd.isEmpty { return URL(fileURLWithPath: cwd).lastPathComponent }
        if !paneId.isEmpty { return paneId }
        return id.uuidString.prefix(8).description
    }

    /// Formatted summary: "Claude · auth-refactor · %12"
    public var summary: String {
        var parts = [agentType.displayName]
        parts.append(displayLabel)
        if !paneId.isEmpty { parts.append(paneId) }
        return parts.joined(separator: " · ")
    }
}
