import SwiftUI
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "Settings")

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("pollMultiplier") private var pollMultiplier = 1.0
    @AppStorage(DesktopPatchManager.automaticPatchingDefaultsKey) private var desktopAutomaticPatchingEnabled = true
    @AppStorage("linuxDevboxMonitorEnabled") private var linuxDevboxMonitorEnabled = false
    @AppStorage("linuxDevboxHost") private var linuxDevboxHost = ""
    @AppStorage("linuxDevboxUser") private var linuxDevboxUser = ""
    @AppStorage("linuxDevboxSSHKeyPath") private var linuxDevboxSSHKeyPath = ""
    @AppStorage("linuxDevboxSSHPort") private var linuxDevboxSSHPort = 22

    var accounts: [CodexAccount] = []
    var onRemoveAllAccounts: (() -> Void)?

    @State private var showingRemoveConfirmation = false
    @State private var versionChecker = CodexVersionChecker()
    @State private var linuxPassphrase = ""
    @State private var linuxPassphraseConfirmation = ""
    @State private var linuxExportResult: LinuxDevboxExportResult?
    @State private var linuxExportError: String?
    @State private var linuxMonitorResult: String?
    @State private var linuxMonitorHealthy: Bool?

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
                        versionChecker.checkVersions()
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
                                Label("Update Now", systemImage: "arrow.down.circle.fill")
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

            Section("Desktop App") {
                Toggle("Automatically repair Codex.app patch", isOn: $desktopAutomaticPatchingEnabled)
                Text("On by default because desktop hot-swap depends on it. CodexSwitch only patches after Codex.app is quit and verifies plugin signatures before reporting ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Linux Devbox") {
                Text("Export encrypted account tokens for the Linux CLI so you do not need to log in again on the VPS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SecureField("Export passphrase", text: $linuxPassphrase)
                SecureField("Confirm passphrase", text: $linuxPassphraseConfirmation)

                Button {
                    exportLinuxBundle()
                } label: {
                    Label("Export All Accounts For Linux", systemImage: "shippingbox.and.arrow.backward")
                }
                .disabled(accounts.isEmpty)

                if let linuxExportResult {
                    Text("Exported \(linuxExportResult.metadata.accountCount) account(s) to \(linuxExportResult.fileURL.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.green)

                    Button("Copy VPS Commands") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            [
                                linuxExportResult.copyCommand,
                                linuxExportResult.importCommand,
                                "ssh user@devbox 'codexswitch-cli tui'",
                            ].joined(separator: "\n"),
                            forType: .string
                        )
                    }

                    Button("Reveal Export In Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([linuxExportResult.fileURL])
                    }
                }

                if let linuxExportError {
                    Text(linuxExportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("This bundle contains encrypted Codex login tokens. Anyone with the file and passphrase can use these accounts. Delete it after importing on the devbox.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Section("Linux Devbox Monitor") {
                Toggle("Notify when VPS auto-swap is not ready", isOn: $linuxDevboxMonitorEnabled)
                TextField("Host", text: $linuxDevboxHost)
                TextField("SSH user", text: $linuxDevboxUser)
                TextField("SSH key path (optional)", text: $linuxDevboxSSHKeyPath)
                Stepper("SSH port: \(linuxDevboxSSHPort)", value: $linuxDevboxSSHPort, in: 1...65535)

                Button("Test VPS Readiness") {
                    testLinuxDevboxMonitor()
                }
                .disabled(!linuxDevboxMonitorEnabled)

                if let linuxMonitorResult {
                    Text(linuxMonitorResult)
                        .font(.caption)
                        .foregroundStyle(linuxMonitorHealthy == true ? .green : .red)
                }

                Text("CodexSwitch checks `codexswitch-cli doctor --json` over SSH and sends a Mac notification if the VPS is not ready for automatic swaps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                LabeledContent("CodexSwitch", value: AppBuildInfo.settingsVersionLabel)
                if let sourceRevision = AppBuildInfo.sourceRevision {
                    LabeledContent("Revision", value: sourceRevision)
                }
                LabeledContent("Auth file", value: "~/.codex/auth.json")
                LabeledContent("Accounts", value: "~/.codexswitch/accounts.json")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 640)
        .onAppear {
            versionChecker.checkVersions()
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

    private func exportLinuxBundle() {
        do {
            let result = try LinuxDevboxExportService().export(
                accounts: accounts,
                passphrase: linuxPassphrase,
                confirmation: linuxPassphraseConfirmation
            )
            linuxExportResult = result
            linuxExportError = nil
        } catch {
            linuxExportResult = nil
            linuxExportError = error.localizedDescription
        }
    }

    private func testLinuxDevboxMonitor() {
        let settings = LinuxDevboxMonitorSettings(
            enabled: linuxDevboxMonitorEnabled,
            host: linuxDevboxHost,
            user: linuxDevboxUser,
            sshKeyPath: linuxDevboxSSHKeyPath,
            port: linuxDevboxSSHPort
        )
        Task.detached {
            let result = LinuxDevboxMonitor.check(settings: settings)
            await MainActor.run {
                switch result {
                case .success(let readiness):
                    linuxMonitorHealthy = readiness.ready
                    linuxMonitorResult = readiness.summary
                case .failure(let failure):
                    linuxMonitorHealthy = false
                    linuxMonitorResult = failure.message
                }
            }
        }
    }
}
