import SwiftUI

@main
struct AgentSentinelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Agent Sentinel", systemImage: "eye.circle.fill") {
            MenuBarContentView()
                .environmentObject(appDelegate.agentRegistry)
                .environmentObject(appDelegate.ipcService)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
