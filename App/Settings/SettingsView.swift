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
            try? newValue.save()
            pushConfigToMonitor(newValue)
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
            }
            .padding()
        }
    }
}
