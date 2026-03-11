import Foundation

/// Application configuration: paths, defaults, load/save.
public struct AppConfig: Codable, Sendable, Equatable {
    public var stallTimeoutSeconds: TimeInterval
    public var maxNotifications: Int
    public var normalDismissSeconds: TimeInterval
    public var highDismissSeconds: TimeInterval
    public var notificationsEnabled: Bool
    public var outputRateLimitLinesPerSec: Int
    public var maxStoredEvents: Int
    public var eventDedupeWindowSeconds: TimeInterval
    public var staleAgentGraceSeconds: TimeInterval
    public var activeAgentTTLSeconds: TimeInterval
    public var actionableEventWindowSeconds: TimeInterval
    public var customRules: [Rule]
    public var disabledBuiltinRuleIds: Set<UUID>
    public var debugMode: Bool

    public init(
        stallTimeoutSeconds: TimeInterval = 120,
        maxNotifications: Int = 5,
        normalDismissSeconds: TimeInterval = 8,
        highDismissSeconds: TimeInterval = 30,
        notificationsEnabled: Bool = true,
        outputRateLimitLinesPerSec: Int = 100,
        maxStoredEvents: Int = 1000,
        eventDedupeWindowSeconds: TimeInterval = 6,
        staleAgentGraceSeconds: TimeInterval = 30,
        activeAgentTTLSeconds: TimeInterval = 900,
        actionableEventWindowSeconds: TimeInterval = 3600,
        customRules: [Rule] = [],
        disabledBuiltinRuleIds: Set<UUID> = [],
        debugMode: Bool = false
    ) {
        self.stallTimeoutSeconds = stallTimeoutSeconds
        self.maxNotifications = maxNotifications
        self.normalDismissSeconds = normalDismissSeconds
        self.highDismissSeconds = highDismissSeconds
        self.notificationsEnabled = notificationsEnabled
        self.outputRateLimitLinesPerSec = outputRateLimitLinesPerSec
        self.maxStoredEvents = maxStoredEvents
        self.eventDedupeWindowSeconds = eventDedupeWindowSeconds
        self.staleAgentGraceSeconds = staleAgentGraceSeconds
        self.activeAgentTTLSeconds = activeAgentTTLSeconds
        self.actionableEventWindowSeconds = actionableEventWindowSeconds
        self.customRules = customRules
        self.disabledBuiltinRuleIds = disabledBuiltinRuleIds
        self.debugMode = debugMode
    }

    private enum CodingKeys: String, CodingKey {
        case stallTimeoutSeconds
        case maxNotifications
        case normalDismissSeconds
        case highDismissSeconds
        case notificationsEnabled
        case outputRateLimitLinesPerSec
        case maxStoredEvents
        case eventDedupeWindowSeconds
        case staleAgentGraceSeconds
        case activeAgentTTLSeconds
        case actionableEventWindowSeconds
        case customRules
        case disabledBuiltinRuleIds
        case debugMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.stallTimeoutSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .stallTimeoutSeconds) ?? 120
        self.maxNotifications = try c.decodeIfPresent(Int.self, forKey: .maxNotifications) ?? 5
        self.normalDismissSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .normalDismissSeconds) ?? 8
        self.highDismissSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .highDismissSeconds) ?? 30
        self.notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        self.outputRateLimitLinesPerSec = try c.decodeIfPresent(Int.self, forKey: .outputRateLimitLinesPerSec) ?? 100
        self.maxStoredEvents = try c.decodeIfPresent(Int.self, forKey: .maxStoredEvents) ?? 1000
        self.eventDedupeWindowSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .eventDedupeWindowSeconds) ?? 6
        self.staleAgentGraceSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .staleAgentGraceSeconds) ?? 30
        self.activeAgentTTLSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .activeAgentTTLSeconds) ?? 900
        self.actionableEventWindowSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .actionableEventWindowSeconds) ?? 3600
        self.customRules = try c.decodeIfPresent([Rule].self, forKey: .customRules) ?? []
        self.disabledBuiltinRuleIds = try c.decodeIfPresent(Set<UUID>.self, forKey: .disabledBuiltinRuleIds) ?? []
        self.debugMode = try c.decodeIfPresent(Bool.self, forKey: .debugMode) ?? false
    }

    // MARK: - Paths

    /// Base directory: ~/.agent-sentinel/
    public static var baseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-sentinel")
    }

    public static var configFile: URL {
        baseDirectory.appendingPathComponent("config.json")
    }

    public static var eventsFile: URL {
        baseDirectory.appendingPathComponent("events.jsonl")
    }

    public static var agentsFile: URL {
        baseDirectory.appendingPathComponent("agents.json")
    }

    public static var socketPath: String {
        baseDirectory.appendingPathComponent("monitor.sock").path
    }

    // MARK: - Directory Setup

    /// Ensure the base directory exists with chmod 0700.
    public static func ensureDirectory() throws {
        let fm = FileManager.default
        let path = baseDirectory.path
        if !fm.fileExists(atPath: path) {
            try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    // MARK: - Load / Save

    public static func load() -> AppConfig {
        do {
            let data = try Data(contentsOf: configFile)
            let decoder = JSONDecoder()
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            SentinelLogger.storage.info("No config found or decode error, using defaults: \(error.localizedDescription)")
            return AppConfig()
        }
    }

    public func save() throws {
        try AppConfig.ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: AppConfig.configFile, options: .atomic)
    }
}
