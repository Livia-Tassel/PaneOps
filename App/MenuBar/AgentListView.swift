import SwiftUI
import SentinelShared

/// List of active agents.
struct AgentListView: View {
    @EnvironmentObject var registry: AgentRegistry

    var body: some View {
        if registry.activeAgents.isEmpty && registry.allAgents.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No agents running")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Use `agent-sentinel run` to start monitoring")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    if !registry.activeAgents.isEmpty {
                        ForEach(registry.activeAgents) { agent in
                            AgentRowView(agent: agent)
                        }
                    }

                    let inactive = registry.allAgents.filter {
                        $0.status == .completed || $0.status == .errored || $0.status == .expired
                    }
                    if !inactive.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                        Text("Recent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)

                        ForEach(inactive.prefix(5)) { agent in
                            AgentRowView(agent: agent)
                                .opacity(0.6)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }
}
