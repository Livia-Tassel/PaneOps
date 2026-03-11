import SwiftUI
import SentinelShared

/// Settings window with notification preferences and timeouts.
struct SettingsView: View {
    @State private var config = AppConfig.load()
    @State private var showingRuleEditor = false
    @State private var editingRule: Rule?

    var body: some View {
        TabView {
            GeneralSettingsView(config: $config)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            RuleListView(config: $config, showingEditor: $showingRuleEditor, editingRule: $editingRule)
                .tabItem {
                    Label("Rules", systemImage: "list.bullet")
                }
        }
        .frame(width: 480, height: 400)
        .onChange(of: config) { _, newValue in
            let normalized = newValue.normalized()
            guard normalized == newValue else {
                config = normalized
                return
            }
            try? normalized.save()
            pushConfigToMonitor(normalized)
        }
        .sheet(isPresented: $showingRuleEditor) {
            RuleEditorView(rule: editingRule) { savedRule in
                if let existing = config.customRules.firstIndex(where: { $0.id == savedRule.id }) {
                    config.customRules[existing] = savedRule
                } else {
                    config.customRules.append(savedRule)
                }
                showingRuleEditor = false
                editingRule = nil
            } onCancel: {
                showingRuleEditor = false
                editingRule = nil
            }
        }
    }

    private func pushConfigToMonitor(_ config: AppConfig) {
        do {
            let client = try IPCClient()
            try client.send(.configUpdate(config))
            client.closeConnection()
        } catch {
            SentinelLogger.ipc.warning("Could not push config update to monitor: \(error.localizedDescription)")
        }
    }
}

struct GeneralSettingsView: View {
    @Binding var config: AppConfig
    @State private var usage = LocalDataMaintenance.usage()
    @State private var isPerformingMaintenance = false
    @State private var maintenanceMessage: String?
    @State private var actionPendingConfirmation: MaintenanceAction?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Notifications") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable notifications", isOn: $config.notificationsEnabled)
                        Stepper("Max visible: \(config.maxNotifications)", value: $config.maxNotifications, in: 1...10)
                        HStack {
                            Text("Normal dismiss:")
                            TextField("", value: $config.normalDismissSeconds, format: .number)
                                .frame(width: 50)
                            Text("seconds")
                        }
                        HStack {
                            Text("Priority dismiss:")
                            TextField("", value: $config.highDismissSeconds, format: .number)
                                .frame(width: 50)
                            Text("seconds")
                        }
                    }
                    .padding(4)
                }

                GroupBox("Monitoring") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Stall timeout:")
                            TextField("", value: $config.stallTimeoutSeconds, format: .number)
                                .frame(width: 50)
                            Text("seconds")
                        }
                        HStack {
                            Text("Active TTL:")
                            TextField("", value: $config.activeAgentTTLSeconds, format: .number)
                                .frame(width: 50)
                            Text("seconds")
                        }
                        HStack {
                            Text("Rate limit:")
                            TextField("", value: $config.outputRateLimitLinesPerSec, format: .number)
                                .frame(width: 50)
                            Text("lines/sec")
                        }
                    }
                    .padding(4)
                }

                GroupBox("Storage") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Max stored events:")
                            TextField("", value: $config.maxStoredEvents, format: .number)
                                .frame(width: 60)
                        }
                        HStack {
                            Text("Actionable window:")
                            TextField("", value: $config.actionableEventWindowSeconds, format: .number)
                                .frame(width: 60)
                            Text("seconds")
                        }
                    }
                    .padding(4)
                }

                GroupBox("Debug") {
                    Toggle("Debug mode (log full output)", isOn: $config.debugMode)
                        .padding(4)
                }

                GroupBox("Data Management") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Total local data:")
                            Spacer()
                            Text(byteString(usage.totalBytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Logs")
                            Spacer()
                            Text(byteString(usage.logsBytes + usage.debugBytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Event history")
                            Spacer()
                            Text(byteString(usage.eventsBytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Agent cache")
                            Spacer()
                            Text(byteString(usage.agentsBytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        HStack(spacing: 8) {
                            Button("Refresh Usage") {
                                refreshUsage()
                            }
                            .disabled(isPerformingMaintenance)

                            Spacer()

                            Button("Clear Logs") {
                                actionPendingConfirmation = .clearLogs
                            }
                            .disabled(isPerformingMaintenance)

                            Button("Clear History") {
                                actionPendingConfirmation = .clearEventHistory
                            }
                            .disabled(isPerformingMaintenance)
                        }

                        HStack(spacing: 8) {
                            Button("Clear Agent Cache") {
                                actionPendingConfirmation = .clearAgentCache
                            }
                            .disabled(isPerformingMaintenance)

                            Spacer()

                            Button("Clear All Runtime Data") {
                                actionPendingConfirmation = .clearAll
                            }
                            .foregroundStyle(.red)
                            .disabled(isPerformingMaintenance)
                        }

                        if let maintenanceMessage {
                            Text(maintenanceMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text("These actions only affect local files under ~/.agent-sentinel.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(4)
                }
            }
            .padding()
        }
        .onAppear {
            refreshUsage()
        }
        .confirmationDialog(
            "Confirm Data Cleanup",
            isPresented: Binding(
                get: { actionPendingConfirmation != nil },
                set: { presented in
                    if !presented { actionPendingConfirmation = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let action = actionPendingConfirmation {
                Button(action.displayName, role: action == .clearAll ? .destructive : .none) {
                    requestMaintenance(action)
                    actionPendingConfirmation = nil
                }
            }
            Button("Cancel", role: .cancel) {
                actionPendingConfirmation = nil
            }
        } message: {
            if let action = actionPendingConfirmation {
                Text(confirmationText(for: action))
            }
        }
    }

    private func refreshUsage() {
        usage = LocalDataMaintenance.usage()
    }

    private func requestMaintenance(_ action: MaintenanceAction) {
        isPerformingMaintenance = true
        maintenanceMessage = "Running \(action.displayName.lowercased())..."

        Task.detached {
            let sentToMonitor: Bool
            do {
                let client = try IPCClient()
                try client.send(.maintenance(MaintenanceRequest(action: action)))
                client.closeConnection()
                sentToMonitor = true
            } catch {
                SentinelLogger.storage.warning("Maintenance IPC unavailable, fallback local cleanup: \(error.localizedDescription)")
                sentToMonitor = false
            }

            let localError: Error?
            if !sentToMonitor {
                do {
                    try LocalDataMaintenance.perform(action)
                    localError = nil
                } catch {
                    localError = error
                }
            } else {
                localError = nil
            }

            let latestUsage = LocalDataMaintenance.usage()
            let message: String
            if let localError {
                message = "Cleanup failed: \(localError.localizedDescription)"
            } else if sentToMonitor {
                message = "\(action.displayName) requested. UI will refresh automatically."
            } else {
                message = "\(action.displayName) completed locally."
            }

            await MainActor.run {
                usage = latestUsage
                isPerformingMaintenance = false
                maintenanceMessage = message
            }
        }
    }

    private func confirmationText(for action: MaintenanceAction) -> String {
        switch action {
        case .clearLogs:
            return "This will truncate app/monitor logs and debug output."
        case .clearEventHistory:
            return "This will remove saved event history from disk."
        case .clearAgentCache:
            return "This will clear cached active/recent agent state."
        case .clearAll:
            return "This will clear logs, event history, and agent cache."
        }
    }

    private func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
