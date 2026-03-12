import Foundation

/// Policy for replaying missed notification events after reconnect.
public enum NotificationReplayPolicy {
    public static func replayableCompletionEvents(
        from events: [AgentEvent],
        now: Date = Date(),
        replayWindowSeconds: TimeInterval,
        alreadyShownEventIDs: Set<UUID>
    ) -> [AgentEvent] {
        events
            .filter { event in
                guard event.eventType == .taskCompleted else { return false }
                guard event.shouldNotify else { return false }
                guard now.timeIntervalSince(event.timestamp) <= replayWindowSeconds else { return false }
                return !alreadyShownEventIDs.contains(event.id)
            }
            .sorted { $0.timestamp < $1.timestamp }
    }
}
