import SwiftUI
import SentinelShared

/// Timeline of recent events.
struct EventListView: View {
    @EnvironmentObject var registry: AgentRegistry
    @State private var showAllEvents = false

    var body: some View {
        if displayedEvents.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bell.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No events yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                HStack {
                    Toggle("Show duplicates", isOn: $showAllEvents)
                        .toggleStyle(.switch)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(displayedEvents) { event in
                            EventRowView(event: event)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var displayedEvents: [AgentEvent] {
        showAllEvents ? registry.timelineEvents : registry.recentEvents
    }
}

struct EventRowView: View {
    let event: AgentEvent
    @EnvironmentObject var registry: AgentRegistry
    @EnvironmentObject var ipcService: IPCService

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: event.eventType.sfSymbol)
                .font(.body)
                .foregroundStyle(eventColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(event.eventType.displayName)
                        .font(.caption.bold())
                        .foregroundStyle(eventColor)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(event.displayLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(event.summary)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(formatTime(event.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if jumpAvailability.isAvailable {
                Button {
                    JumpController.jumpToPane(
                        paneId: event.paneId,
                        windowId: event.windowId,
                        sessionName: event.sessionName
                    )
                    registry.acknowledgeEvent(id: event.id)
                    ipcService.send(.ack(messageId: event.id))
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            EventPolicy.isActionable(
                event,
                now: Date(),
                actionableWindowSeconds: registry.config.actionableEventWindowSeconds,
                activeAgentIDs: registry.activeAgentIDs
            ) ? Color.accentColor.opacity(0.05) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
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

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private var jumpAvailability: JumpAvailability {
        JumpPolicy.availability(for: event)
    }
}
