import SwiftUI
import SentinelShared

/// Main content of the menu bar popover.
struct MenuBarContentView: View {
    @EnvironmentObject var registry: AgentRegistry
    @EnvironmentObject var ipcService: IPCService
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "eye.circle.fill")
                    .foregroundStyle(.blue)
                Text("Agent Sentinel")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(registry.monitorConnected ? .green : .orange)
                    .frame(width: 8, height: 8)
                    .help(registry.monitorConnected ? "Monitor connected" : "Monitor reconnecting")
                if registry.unacknowledgedCount > 0 {
                    Text("\(registry.unacknowledgedCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Tab selector
            Picker("View", selection: $selectedTab) {
                Text("Agents (\(registry.activeAgents.count))").tag(0)
                Text("Events").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Content
            if selectedTab == 0 {
                AgentListView()
            } else {
                EventListView()
            }

            Divider()

            // Footer
            VStack(spacing: 8) {
                Toggle("Notifications", isOn: Binding(
                    get: { registry.config.notificationsEnabled },
                    set: { enabled in
                        registry.config.notificationsEnabled = enabled
                        ipcService.send(.configUpdate(registry.config))
                    }
                ))
                .toggleStyle(.switch)
                .font(.caption)

                HStack {
                    Button("Acknowledge All") {
                        registry.acknowledgeAll()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("History") {
                        selectedTab = 1
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    SettingsLink {
                        Text("Rules & Settings")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 340, height: 420)
    }
}
