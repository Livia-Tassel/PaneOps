import Foundation

/// Append-only JSONL event store with rotation.
public final class EventStore: @unchecked Sendable {
    private let fileURL: URL
    private let maxLines: Int
    private let lock = NSLock()

    public init(fileURL: URL = AppConfig.eventsFile, maxLines: Int = 1000) {
        self.fileURL = fileURL
        self.maxLines = maxLines
    }

    /// Append an event as a JSONL line.
    public func append(_ event: AgentEvent) throws {
        try AppConfig.ensureDirectory()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        guard var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        lock.lock()
        defer { lock.unlock() }

        let handle: FileHandle
        if FileManager.default.fileExists(atPath: fileURL.path) {
            handle = try FileHandle(forWritingTo: fileURL)
            handle.seekToEndOfFile()
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: fileURL)
        }

        handle.write(line.data(using: .utf8)!)
        handle.closeFile()

        rotateIfNeeded()
    }

    /// Rewrite the event file with the provided full event list.
    public func rewrite(_ events: [AgentEvent]) throws {
        try AppConfig.ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let content = try events.map { event -> String in
            let data = try encoder.encode(event)
            guard let line = String(data: data, encoding: .utf8) else {
                return ""
            }
            return line
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

        lock.lock()
        defer { lock.unlock() }

        let finalContent = content.isEmpty ? "" : content + "\n"
        let data = finalContent.data(using: .utf8) ?? Data()
        try data.write(to: fileURL, options: .atomic)
    }

    /// Load the most recent N events.
    public func loadRecent(_ count: Int = 50) -> [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let recentLines = lines.suffix(count)

        return recentLines.compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AgentEvent.self, from: lineData)
        }
    }

    /// Load all events.
    public func loadAll() -> [AgentEvent] {
        loadRecent(maxLines)
    }

    // MARK: - Private

    private func rotateIfNeeded() {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count > maxLines else { return }

        // Keep only the most recent maxLines
        let kept = lines.suffix(maxLines)
        let newContent = kept.joined(separator: "\n") + "\n"

        try? newContent.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        SentinelLogger.storage.info("Rotated event store: \(lines.count) → \(kept.count) entries")
    }
}
