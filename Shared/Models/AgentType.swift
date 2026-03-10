import Foundation

/// The type of AI coding agent being monitored.
public enum AgentType: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case gemini
    case custom

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .custom: return "Custom"
        }
    }

    /// Attempt to detect agent type from a command string.
    public static func detect(from command: String) -> AgentType {
        let lower = command.lowercased()
        if lower.contains("claude") { return .claude }
        if lower.contains("codex") { return .codex }
        if lower.contains("gemini") { return .gemini }
        return .custom
    }
}
