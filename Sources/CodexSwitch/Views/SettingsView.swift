import SwiftUI
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "Settings")

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("pollMultiplier") private var pollMultiplier = 1.0

    var onRemoveAllAccounts: (() -> Void)?

    @State private var showingRemoveConfirmation = false
    @State private var versionChecker = CodexVersionChecker()

    private static let lastCheckedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d @ h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

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

            Section("Codex CLI") {
                HStack {
                    Text("Installed")
                    Spacer()
                    Text("v\(versionChecker.installedVersion)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Latest")
                    Spacer()
                    if versionChecker.updateAvailable {
                        Text("v\(versionChecker.latestVersion)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange)
                    } else {
                        Text("v\(versionChecker.latestVersion)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button {
                        versionChecker.checkVersions(force: true)
                    } label: {
                        if versionChecker.isChecking {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking...")
                        } else {
                            Label("Check for Updates", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(versionChecker.isChecking || versionChecker.isUpdating)

                    if versionChecker.updateAvailable {
                        Button {
                            versionChecker.runUpdate()
                        } label: {
                            if versionChecker.isUpdating {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Updating...")
                            } else {
                                Label(
                                    versionChecker.forkInstalled ? "Update and Patch Now" : "Update Now",
                                    systemImage: "arrow.down.circle.fill"
                                )
                            }
                        }
                        .disabled(versionChecker.isUpdating)
                    }
                }

                if versionChecker.forkInstalled {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("SIGHUP fork installed")
                            .font(.caption)
                            .foregroundStyle(.green)
                        if versionChecker.forkRebuilding {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Rebuilding...")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let result = versionChecker.updateResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(versionChecker.updateSucceeded ? .green : .red)
                        .lineLimit(3)
                }

                if let lastChecked = versionChecker.lastChecked {
                    Text("Last checked: \(Self.lastCheckedFormatter.string(from: lastChecked))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Not checked yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Codex Desktop App") {
                HStack {
                    Text("Installed")
                    Spacer()
                    Text(versionChecker.desktopInstalledVersionLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Latest")
                    Spacer()
                    Text(versionChecker.desktopLatestVersionLabel)
                        .font(.system(size: 11, weight: versionChecker.desktopUpdateAvailable ? .medium : .regular, design: .monospaced))
                        .foregroundStyle(versionChecker.desktopUpdateAvailable ? .orange : .secondary)
                }

                HStack(alignment: .top) {
                    Text("Runtime")
                    Spacer()
                    Text(versionChecker.desktopRuntimeLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                HStack(alignment: .top) {
                    Text("Auto-Swap")
                    Spacer()
                    Text(versionChecker.desktopAutoSwapLabel)
                        .font(.system(size: 11, weight: versionChecker.desktopAutoSwapReady ? .regular : .medium, design: .monospaced))
                        .foregroundStyle(versionChecker.desktopAutoSwapReady ? .green : .orange)
                        .multilineTextAlignment(.trailing)
                }

                HStack(alignment: .top) {
                    Text("Patch")
                    Spacer()
                    Text(versionChecker.desktopPatchLabel)
                        .font(.system(size: 11, weight: versionChecker.desktopPatchHealthy ? .regular : .medium, design: .monospaced))
                        .foregroundStyle(versionChecker.desktopPatchHealthy ? .green : .orange)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Button {
                        versionChecker.checkVersions(force: true)
                    } label: {
                        Label("Refresh Desktop Status", systemImage: "arrow.clockwise")
                    }
                    .disabled(versionChecker.isChecking || versionChecker.desktopPatchInFlight || versionChecker.desktopUpdateInFlight)

                    if versionChecker.desktopUpdateAvailable {
                        Button {
                            versionChecker.installLatestDesktopNow()
                        } label: {
                            if versionChecker.desktopUpdateInFlight {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Updating...")
                            } else {
                                Label("Install Latest Stock App", systemImage: "arrow.down.circle.fill")
                            }
                        }
                        .disabled(versionChecker.desktopUpdateInFlight || versionChecker.desktopPatchInFlight)
                    } else if versionChecker.desktopCanPatchNow || !versionChecker.desktopPatchHealthy {
                        Button {
                            versionChecker.restoreDesktopAppNow()
                        } label: {
                            if versionChecker.desktopPatchInFlight {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Restoring...")
                            } else {
                                Label("Restore Stock App", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(versionChecker.desktopPatchInFlight)
                    }
                }

                if let result = versionChecker.desktopPatchResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(versionChecker.desktopPatchSucceeded ? .green : .red)
                        .lineLimit(4)
                }

                if let result = versionChecker.desktopUpdateResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(versionChecker.desktopUpdateSucceeded ? .green : .red)
                        .lineLimit(4)
                }
            }

            Section("Data") {
                Button("Remove All Accounts", role: .destructive) {
                    showingRemoveConfirmation = true
                }
                .confirmationDialog(
                    "Remove all accounts?",
                    isPresented: $showingRemoveConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Remove All", role: .destructive) {
                        onRemoveAllAccounts?()
                    }
                } message: {
                    Text("This will delete all stored account data. You'll need to re-import accounts.")
                }
                Text("Removes all stored tokens and account data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("CodexSwitch", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                LabeledContent("Auth file", value: "~/.codex/auth.json")
                LabeledContent("Accounts", value: "~/.codexswitch/accounts.json")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 620)
        .onAppear {
            versionChecker.checkVersions()
        }
        .task {
            versionChecker.refreshDesktopRuntimeStatus()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                versionChecker.refreshDesktopRuntimeStatus()
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enabled
            logger.error("Launch at login toggle failed: \(error.localizedDescription)")
        }
    }
}
