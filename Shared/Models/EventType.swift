import Foundation

/// Types of events the sentinel can detect from agent output.
public enum EventType: String, Codable, Sendable, CaseIterable {
    case permissionRequested
    case inputRequested
    case taskCompleted
    case errorDetected
    case stalledOrWaiting

    public var icon: String {
        switch self {
        case .permissionRequested: return "⚠️"
        case .inputRequested: return "💬"
        case .taskCompleted: return "✅"
        case .errorDetected: return "❌"
        case .stalledOrWaiting: return "⏸️"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .permissionRequested: return "exclamationmark.shield"
        case .inputRequested: return "text.bubble"
        case .taskCompleted: return "checkmark.circle"
        case .errorDetected: return "xmark.octagon"
        case .stalledOrWaiting: return "pause.circle"
        }
    }

    /// Auto-dismiss timeout in seconds. Higher priority events stay longer.
    public var autoDismissSeconds: TimeInterval {
        switch self {
        case .permissionRequested: return 30
        case .inputRequested: return 30
        case .taskCompleted: return 8
        case .errorDetected: return 15
        case .stalledOrWaiting: return 8
        }
    }

    /// Keep important items pinned in the overlay until user handles them.
    public var requiresManualDismissInOverlay: Bool {
        switch self {
        case .permissionRequested, .inputRequested, .taskCompleted:
            return true
        case .errorDetected, .stalledOrWaiting:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .permissionRequested: return "Permission Requested"
        case .inputRequested: return "Input Requested"
        case .taskCompleted: return "Task Completed"
        case .errorDetected: return "Error Detected"
        case .stalledOrWaiting: return "Stalled"
        }
    }

    /// Color name used for notification theming.
    public var colorName: String {
        switch self {
        case .permissionRequested: return "orange"
        case .inputRequested: return "blue"
        case .taskCompleted: return "green"
        case .errorDetected: return "red"
        case .stalledOrWaiting: return "gray"
        }
    }
}
