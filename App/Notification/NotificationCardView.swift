import SwiftUI
import SentinelShared

/// Aggregated notification card content.
struct NotificationCardView: View {
    let events: [AgentEvent]
    let onDismiss: (UUID) -> Void
    let onJump: (AgentEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent Sentinel")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(events.count) event\(events.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ForEach(events) { event in
                EventCardRow(event: event, onDismiss: onDismiss, onJump: onJump)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct EventCardRow: View {
    let event: AgentEvent
    let onDismiss: (UUID) -> Void
    let onJump: (AgentEvent) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor)
                .frame(width: 4, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(event.agentType.displayName) · \(event.displayLabel)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(formatted(event.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(event.eventType.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(eventColor)
                Text(event.summary)
                    .font(.caption2)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                Button {
                    onJump(event)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .disabled(event.paneId.isEmpty)

                Button {
                    onDismiss(event.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private var eventColor: Color {
        switch event.eventType {
        case .permissionRequested: return .orange
        case .inputRequested: return .blue
        case .taskCompleted: return .green
        case .errorDetected: return .red
        case .stalledOrWaiting: return .gray
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
