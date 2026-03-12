import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("pollMultiplier") private var pollMultiplier = 1.0

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                Toggle("Notifications", isOn: $notificationsEnabled)
            }

            Section("Polling") {
                HStack {
                    Text("Poll frequency")
                    Slider(value: $pollMultiplier, in: 0.5...2.0, step: 0.25)
                    Text("\(pollMultiplier, specifier: "%.2f")x")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 40)
                }
                Text("Adjusts base polling intervals. 1.0x = default, 0.5x = faster, 2.0x = slower.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                Button("Remove All Accounts", role: .destructive) {
                    // Will be wired in integration
                }
                Text("This removes all stored tokens from Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Auth file", value: "~/.codex/auth.json")
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 320)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Launch at login toggle failed: \(error)")
        }
    }
}
