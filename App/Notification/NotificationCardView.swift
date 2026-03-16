import SwiftUI
import SentinelShared

/// Aggregated notification card content.
struct NotificationCardView: View {
    let events: [AgentEvent]
    let onDismiss: (UUID) -> Void
    let onJump: (AgentEvent) -> Void
    let onSendKeys: (String, String, Bool) -> Void // (paneId, text, enterAfter)

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
                EventCardRow(
                    event: event,
                    onDismiss: onDismiss,
                    onJump: onJump,
                    onSendKeys: onSendKeys
                )
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
    let onSendKeys: (String, String, Bool) -> Void
    @State private var replyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row
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
                    if jumpAvailability.isAvailable {
                        Button {
                            onJump(event)
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }

                    Button {
                        onDismiss(event.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            // Context lines (if available)
            if let contextLines = event.contextLines, !contextLines.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(contextLines.indices, id: \.self) { idx in
                        Text(contextLines[idx])
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
            }

            // Action buttons for permission requests
            if event.eventType == .permissionRequested, !event.paneId.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        onSendKeys(event.paneId, "y", true)
                        onDismiss(event.id)
                    } label: {
                        Label("Yes", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.green)

                    Button {
                        onSendKeys(event.paneId, "n", true)
                        onDismiss(event.id)
                    } label: {
                        Label("No", systemImage: "xmark.circle.fill")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
                .padding(.leading, 12)
            }

            // Reply text field for completions and input requests
            if (event.eventType == .taskCompleted || event.eventType == .inputRequested),
               !event.paneId.isEmpty {
                HStack(spacing: 6) {
                    TextField("Reply...", text: $replyText)
                        .textFieldStyle(.plain)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .onSubmit {
                            sendReply()
                        }

                    Button {
                        sendReply()
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(replyText.isEmpty ? Color.secondary : Color.blue)
                    .disabled(replyText.isEmpty)
                }
                .padding(.leading, 12)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSendKeys(event.paneId, text, true)
        replyText = ""
        onDismiss(event.id)
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

    private var jumpAvailability: JumpAvailability {
        JumpPolicy.availability(for: event)
    }
}
