import SwiftUI
import SentinelShared

/// Row displaying a single agent instance.
struct AgentRowView: View {
    let agent: AgentInstance

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            // Agent info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(agent.agentType.displayName)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(agent.displayLabel)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .help("Label priority: task label > window name > cwd folder > pane id")
                }

                HStack(spacing: 4) {
                    Text(contextText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(contextColor)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(agent.status.rawValue)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                    Spacer()
                    Text(timeAgo(agent.lastActiveAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Jump button
            if jumpAvailability.isAvailable {
                Button {
                    JumpController.jump(to: agent)
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Jump to pane \(agent.paneId)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private var statusColor: Color {
        switch agent.status {
        case .running: return .green
        case .waiting: return .orange
        case .completed: return .green
        case .errored: return .red
        case .stalled: return .gray
        case .expired: return .secondary
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    private var jumpAvailability: JumpAvailability {
        JumpPolicy.availability(for: agent)
    }

    private var contextText: String {
        if let reason = jumpAvailability.reason, agent.status.isActive {
            return reason
        }
        return agent.paneDisplayLabel
    }

    private var contextColor: Color {
        if jumpAvailability.isAvailable {
            return .secondary
        }
        return agent.status.isActive ? .orange : .secondary
    }
}
