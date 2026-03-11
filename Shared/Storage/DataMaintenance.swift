import Foundation

public enum MaintenanceAction: String, Codable, Sendable, CaseIterable {
    case clearLogs
    case clearEventHistory
    case clearAgentCache
    case clearAll

    public var displayName: String {
        switch self {
        case .clearLogs: return "Clear Logs"
        case .clearEventHistory: return "Clear Event History"
        case .clearAgentCache: return "Clear Agent Cache"
        case .clearAll: return "Clear All Runtime Data"
        }
    }
}

public struct MaintenanceRequest: Codable, Sendable {
    public let action: MaintenanceAction

    public init(action: MaintenanceAction) {
        self.action = action
    }
}

public struct StorageUsage: Sendable {
    public let logsBytes: UInt64
    public let debugBytes: UInt64
    public let eventsBytes: UInt64
    public let agentsBytes: UInt64

    public var totalBytes: UInt64 {
        logsBytes + debugBytes + eventsBytes + agentsBytes
    }

    public init(logsBytes: UInt64, debugBytes: UInt64, eventsBytes: UInt64, agentsBytes: UInt64) {
        self.logsBytes = logsBytes
        self.debugBytes = debugBytes
        self.eventsBytes = eventsBytes
        self.agentsBytes = agentsBytes
    }
}

/// Local-only storage maintenance helpers used by settings and monitor.
public enum LocalDataMaintenance {
    public static var logsDirectory: URL {
        AppConfig.baseDirectory.appendingPathComponent("logs")
    }

    public static var debugLogFile: URL {
        AppConfig.baseDirectory.appendingPathComponent("debug-output.log")
    }

    public static func usage() -> StorageUsage {
        StorageUsage(
            logsBytes: directorySize(at: logsDirectory),
            debugBytes: fileSize(at: debugLogFile),
            eventsBytes: fileSize(at: AppConfig.eventsFile),
            agentsBytes: fileSize(at: AppConfig.agentsFile)
        )
    }

    public static func perform(_ action: MaintenanceAction) throws {
        try AppConfig.ensureDirectory()
        switch action {
        case .clearLogs:
            try clearLogs()
        case .clearEventHistory:
            try truncate(AppConfig.eventsFile)
        case .clearAgentCache:
            try writeAgentCache([])
        case .clearAll:
            try clearLogs()
            try truncate(AppConfig.eventsFile)
            try writeAgentCache([])
        }
    }

    public static func clearLogs() throws {
        try AppConfig.ensureDirectory()
        if FileManager.default.fileExists(atPath: logsDirectory.path) {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: logsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries where entry.pathExtension == "log" {
                try truncate(entry)
            }
        }
        if FileManager.default.fileExists(atPath: debugLogFile.path) {
            try truncate(debugLogFile)
        }
    }

    // MARK: - Private

    private static func fileSize(at url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    private static func directorySize(at url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += UInt64(values.fileSize ?? 0)
        }
        return total
    }

    private static func truncate(_ fileURL: URL) throws {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)
        try handle.close()
    }

    private static func writeAgentCache(_ agents: [AgentInstance]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(agents)
        try data.write(to: AppConfig.agentsFile, options: .atomic)
    }
}
