import Foundation

public enum IPCClientKind: String, Codable, Sendable {
    case app
    case wrapper
}

public struct SubscribeRequest: Codable, Sendable {
    public let clientId: UUID
    public let kind: IPCClientKind

    public init(clientId: UUID = UUID(), kind: IPCClientKind) {
        self.clientId = clientId
        self.kind = kind
    }
}

public struct MonitorSnapshot: Codable, Sendable {
    public let agents: [AgentInstance]
    public let events: [AgentEvent]
    public let config: AppConfig

    public init(agents: [AgentInstance], events: [AgentEvent], config: AppConfig) {
        self.agents = agents
        self.events = events
        self.config = config
    }
}

/// Messages exchanged between wrapper/app and the monitor daemon.
public enum IPCMessage: Codable, Sendable {
    case register(AgentInstance)
    case event(AgentEvent)
    case deregister(agentId: UUID, exitCode: Int32)
    case heartbeat(agentId: UUID)
    case subscribe(SubscribeRequest)
    case snapshot(MonitorSnapshot)
    case ack(messageId: UUID)
    case configUpdate(AppConfig)
    case maintenance(MaintenanceRequest)

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum MessageType: String, Codable {
        case register
        case event
        case deregister
        case heartbeat
        case subscribe
        case snapshot
        case ack
        case configUpdate
        case maintenance
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .register(let agent):
            try container.encode(MessageType.register, forKey: .type)
            try container.encode(agent, forKey: .payload)
        case .event(let event):
            try container.encode(MessageType.event, forKey: .type)
            try container.encode(event, forKey: .payload)
        case .deregister(let agentId, let exitCode):
            try container.encode(MessageType.deregister, forKey: .type)
            try container.encode(DeregisterPayload(agentId: agentId, exitCode: exitCode), forKey: .payload)
        case .heartbeat(let agentId):
            try container.encode(MessageType.heartbeat, forKey: .type)
            try container.encode(HeartbeatPayload(agentId: agentId), forKey: .payload)
        case .subscribe(let request):
            try container.encode(MessageType.subscribe, forKey: .type)
            try container.encode(request, forKey: .payload)
        case .snapshot(let snapshot):
            try container.encode(MessageType.snapshot, forKey: .type)
            try container.encode(snapshot, forKey: .payload)
        case .ack(let messageId):
            try container.encode(MessageType.ack, forKey: .type)
            try container.encode(AckPayload(messageId: messageId), forKey: .payload)
        case .configUpdate(let config):
            try container.encode(MessageType.configUpdate, forKey: .type)
            try container.encode(config, forKey: .payload)
        case .maintenance(let request):
            try container.encode(MessageType.maintenance, forKey: .type)
            try container.encode(request, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .register:
            self = .register(try container.decode(AgentInstance.self, forKey: .payload))
        case .event:
            self = .event(try container.decode(AgentEvent.self, forKey: .payload))
        case .deregister:
            let payload = try container.decode(DeregisterPayload.self, forKey: .payload)
            self = .deregister(agentId: payload.agentId, exitCode: payload.exitCode)
        case .heartbeat:
            let payload = try container.decode(HeartbeatPayload.self, forKey: .payload)
            self = .heartbeat(agentId: payload.agentId)
        case .subscribe:
            self = .subscribe(try container.decode(SubscribeRequest.self, forKey: .payload))
        case .snapshot:
            self = .snapshot(try container.decode(MonitorSnapshot.self, forKey: .payload))
        case .ack:
            let payload = try container.decode(AckPayload.self, forKey: .payload)
            self = .ack(messageId: payload.messageId)
        case .configUpdate:
            self = .configUpdate(try container.decode(AppConfig.self, forKey: .payload))
        case .maintenance:
            self = .maintenance(try container.decode(MaintenanceRequest.self, forKey: .payload))
        }
    }
}

private struct DeregisterPayload: Codable {
    let agentId: UUID
    let exitCode: Int32
}

private struct HeartbeatPayload: Codable {
    let agentId: UUID
}

private struct AckPayload: Codable {
    let messageId: UUID
}
