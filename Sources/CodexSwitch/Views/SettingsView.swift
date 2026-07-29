import AppKit
import SwiftUI
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "Settings")

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("pollMultiplier") private var pollMultiplier = 1.0
    @AppStorage(RateLimitResetSettings.automaticRedemptionDefaultsKey) private var automaticRateLimitResetRedemption = true
    @AppStorage(DesktopPatchManager.automaticPatchingDefaultsKey) private var desktopAutomaticPatchingEnabled = true
    @AppStorage("linuxDevboxMonitorEnabled") private var linuxDevboxMonitorEnabled = false
    @AppStorage("linuxDevboxHost") private var linuxDevboxHost = ""
    @AppStorage("linuxDevboxUser") private var linuxDevboxUser = ""
    @AppStorage("linuxDevboxSSHKeyPath") private var linuxDevboxSSHKeyPath = ""
    @AppStorage("linuxDevboxSSHPort") private var linuxDevboxSSHPort = 22
    @AppStorage(LinuxDevboxMonitorSettings.resetAuthorityModeDefaultsKey)
    private var resetAuthorityModeRawValue = AutomaticRateLimitResetOwner.vpsAuthority.rawValue

    var accounts: [CodexAccount] = []
    var rateLimitResetPresentations: [UUID: RateLimitResetInventoryPresentation] = [:]
    var onRemoveAllAccounts: (() -> Void)?
    @ObservedObject var desktopUpdateCoordinator: CodexDesktopUpdateCoordinator
    var onInstallDesktopUpdate: (() -> Void)?
    var onRetryDesktopPatch: ((
        @escaping @MainActor @Sendable (DesktopPatchAttemptOutcome) -> Void
    ) -> Void)?

    @State private var showingRemoveConfirmation = false
    @State private var appManagementPermissionRequired = false
    @State private var desktopPatchRetryInProgress = false
    @State private var versionChecker = CodexVersionChecker()
    @State private var linuxPassphrase = ""
    @State private var linuxPassphraseConfirmation = ""
    @State private var linuxExportResult: LinuxDevboxExportResult?
    @State private var linuxExportError: String?
    @State private var linuxMonitorResult: String?
    @State private var linuxMonitorHealthy: Bool?
    @State private var remoteAutomaticResetPolicy: LinuxDevboxAutomaticResetPolicyObservation?
    @State private var remoteAutomaticResetPolicyStatus: String?
    @State private var remoteAutomaticResetPolicyStatusIsError = false
    @State private var remoteAutomaticResetPolicyIsBusy = false
    @State private var remoteAutomaticResetPolicyRequestGeneration: UInt64 = 0

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

            Section("Banked Resets") {
                Picker(
                    "Reset authority",
                    selection: Binding(
                        get: { automaticResetAuthorityMode },
                        set: { updateAutomaticResetAuthorityMode(to: $0) }
                    )
                ) {
                    Text("VPS").tag(AutomaticRateLimitResetOwner.vpsAuthority)
                    Text("This Mac").tag(AutomaticRateLimitResetOwner.macStandalone)
                }
                .pickerStyle(.segmented)
                .disabled(linuxDevboxSettings.hasRemoteAuthorityEndpoint)

                HStack {
                    Toggle(
                        "Automatically use banked resets",
                        isOn: Binding(
                            get: { automaticResetPolicyToggleValue },
                            set: { updateAutomaticResetPolicy(to: $0) }
                        )
                    )
                    .disabled(!automaticResetPolicyToggleAllowsMutation)

                    if linuxDevboxSettings.usesVPSResetAuthority {
                        if remoteAutomaticResetPolicyIsBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button {
                                Task { await refreshAutomaticResetPolicy() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Refresh VPS automatic-reset policy")
                        }
                    }
                }

                if linuxDevboxSettings.usesVPSResetAuthority,
                   let remoteAutomaticResetPolicyStatus {
                    Text(remoteAutomaticResetPolicyStatus)
                        .font(.caption)
                        .foregroundStyle(
                            remoteAutomaticResetPolicyStatusIsError ? .red : .secondary
                        )
                }
                Label(
                    PooledUsageMeterView.routingTierStatusText(for: accounts),
                    systemImage: "list.number"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Label(
                    Self.resetInventoryStatusText(
                        accounts: accounts,
                        presentations: rateLimitResetPresentations,
                        now: Date()
                    ),
                    systemImage: "arrow.counterclockwise.circle"
                )
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
                HStack {
                    Text("Installed")
                    Spacer()
                    Text(
                        desktopUpdateCoordinator.presentation.installedVersion
                            ?? "Not found"
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Latest")
                    Spacer()
                    Text(
                        desktopUpdateCoordinator.presentation.latestVersion
                            ?? "Not checked"
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                }

                if let staged = desktopUpdateCoordinator.presentation.stagedVersion {
                    HStack {
                        Text("Staged")
                        Spacer()
                        Text(staged)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(
                                desktopUpdateCoordinator.presentation.phase == .staged
                                    ? .orange
                                    : .secondary
                            )
                    }
                }

                HStack {
                    Button {
                        desktopUpdateCoordinator.prepareLatestUpdateNow()
                    } label: {
                        if desktopUpdateCoordinator.presentation.phase == .checking {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking...")
                        } else {
                            Label(
                                "Check & Prepare Update",
                                systemImage: "arrow.down.circle"
                            )
                        }
                    }
                    .disabled(desktopUpdateCoordinator.presentation.isBusy)

                    if desktopUpdateCoordinator.presentation.phase == .staged {
                        Button {
                            onInstallDesktopUpdate?()
                        } label: {
                            Label("Install Update", systemImage: "arrow.down.app")
                        }
                        .disabled(desktopUpdateCoordinator.presentation.isBusy)
                    }
                }

                Text(desktopUpdateCoordinator.presentation.message)
                    .font(.caption)
                    .foregroundStyle(desktopUpdateStatusColor)

                if let lastChecked = desktopUpdateCoordinator.presentation.lastCheckedAt {
                    Text(
                        "Last checked: "
                            + Self.lastCheckedFormatter.string(from: lastChecked)
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }

                if appManagementPermissionRequired {
                    Label(
                        "App Management permission required",
                        systemImage: "lock.trianglebadge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)

                    HStack {
                        Button {
                            openPrivacyAndSecurity()
                        } label: {
                            Label("Open Privacy & Security", systemImage: "gear")
                        }

                        Button {
                            guard let onRetryDesktopPatch else { return }
                            desktopPatchRetryInProgress = true
                            onRetryDesktopPatch { outcome in
                                desktopPatchRetryInProgress = false
                                switch outcome {
                                case .completed, .notNeeded:
                                    appManagementPermissionRequired = false
                                default:
                                    appManagementPermissionRequired = true
                                }
                            }
                        } label: {
                            if desktopPatchRetryInProgress {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Retrying...")
                            } else {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(desktopPatchRetryInProgress)
                    }
                }

                Toggle(
                    "Automatically restore hot swapping after updates",
                    isOn: $desktopAutomaticPatchingEnabled
                )
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
                                "ssh user@devbox 'codexswitch-cli doctor'",
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
                .disabled(!linuxDevboxSettings.isConfigured)

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
            appManagementPermissionRequired =
                DesktopPatchManager.appManagementPermissionRequired
        }
        .onChange(of: desktopUpdateCoordinator.presentation) {
            appManagementPermissionRequired =
                DesktopPatchManager.appManagementPermissionRequired
        }
        .onChange(of: linuxDevboxSettings.hasRemoteAuthorityEndpoint) { _, isConfigured in
            if isConfigured {
                resetAuthorityModeRawValue = AutomaticRateLimitResetOwner.vpsAuthority.rawValue
            }
        }
        .task(id: linuxDevboxSettings) {
            await refreshAutomaticResetPolicy()
        }
    }

    static func resetInventoryStatusText(
        accounts: [CodexAccount],
        presentations: [UUID: RateLimitResetInventoryPresentation],
        now: Date
    ) -> String {
        let resolvedPresentations = Dictionary(uniqueKeysWithValues: accounts.map { account in
            if let presentation = presentations[account.id] {
                return (account.id, presentation)
            }
            let bank = account.rateLimitResetBank
            let hasExpiredAvailableCredit = bank?.credits.contains { credit in
                credit.isAvailable && credit.expiresAt.map { $0 <= now } == true
            } ?? false
            return (
                account.id,
                RateLimitResetInventoryPresentation.resolve(
                    availableCount: bank?.availableCount ?? 0,
                    nextExpiration: bank?.nextExpiration(at: now),
                    inventoryIsFresh: bank.map {
                        $0.isFresh(
                            at: now,
                            maxAge: RateLimitResetInventoryObservation.presentationMaximumAge
                        ) && $0.structurallyValidAvailableCredits(at: now) != nil
                    } ?? false,
                    inventoryExists: bank != nil,
                    inventoryHasExpiredAvailableCredit: hasExpiredAvailableCredit,
                    inventoryIsStructurallyValid: bank.map {
                        $0.structurallyValidAvailableCredits(at: now) != nil
                    } ?? false,
                    now: now
                )
            )
        })
        let summary = PooledRateLimitResetPresentation.summarize(
            accounts: accounts,
            presentations: resolvedPresentations,
            now: now
        )
        return PooledUsageMeterView.rateLimitResetStatusText(
            for: summary,
            nextExpirationText: nil,
            fetchedAtText: summary.currentCountFetchedAt.map {
                PooledUsageMeterView.inventoryAgeText(fetchedAt: $0, now: now)
            }
        )
    }

    private var desktopUpdateStatusColor: Color {
        switch desktopUpdateCoordinator.presentation.phase {
        case .current:
            return .green
        case .staged, .waitingForQuit, .installing, .deferred:
            return .orange
        case .failed:
            return .red
        case .idle, .checking:
            return .secondary
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

    private func openPrivacyAndSecurity() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
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
        let settings = linuxDevboxSettings
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

    static func automaticResetPolicyToggleValue(
        localPreference: Bool,
        settings: LinuxDevboxMonitorSettings,
        remoteObservation: LinuxDevboxAutomaticResetPolicyObservation?
    ) -> Bool {
        guard settings.usesVPSResetAuthority else {
            return localPreference
        }
        return remoteObservation?.automaticRateLimitResetRedemption ?? false
    }

    static func automaticResetPolicyToggleAllowsMutation(
        settings: LinuxDevboxMonitorSettings,
        remoteObservation: LinuxDevboxAutomaticResetPolicyObservation?,
        isBusy: Bool
    ) -> Bool {
        guard !isBusy else { return false }
        guard settings.usesVPSResetAuthority else { return true }
        return settings.hasUsableVPSResetAuthorityTransport
            && remoteObservation != nil
    }

    private var automaticResetPolicyToggleValue: Bool {
        Self.automaticResetPolicyToggleValue(
            localPreference: automaticRateLimitResetRedemption,
            settings: linuxDevboxSettings,
            remoteObservation: remoteAutomaticResetPolicy
        )
    }

    private var automaticResetPolicyToggleAllowsMutation: Bool {
        Self.automaticResetPolicyToggleAllowsMutation(
            settings: linuxDevboxSettings,
            remoteObservation: remoteAutomaticResetPolicy,
            isBusy: remoteAutomaticResetPolicyIsBusy
        )
    }

    @MainActor
    private func refreshAutomaticResetPolicy() async {
        let settings = linuxDevboxSettings
        remoteAutomaticResetPolicyRequestGeneration &+= 1
        let generation = remoteAutomaticResetPolicyRequestGeneration

        guard settings.usesVPSResetAuthority else {
            remoteAutomaticResetPolicy = nil
            remoteAutomaticResetPolicyStatus = nil
            remoteAutomaticResetPolicyStatusIsError = false
            remoteAutomaticResetPolicyIsBusy = false
            return
        }

        guard settings.hasRemoteAuthorityEndpoint else {
            remoteAutomaticResetPolicy = nil
            remoteAutomaticResetPolicyStatus =
                "VPS reset authority endpoint is unavailable; local fallback is disabled"
            remoteAutomaticResetPolicyStatusIsError = true
            remoteAutomaticResetPolicyIsBusy = false
            return
        }

        remoteAutomaticResetPolicyIsBusy = true
        remoteAutomaticResetPolicyStatus = "Reading automatic-reset policy from VPS..."
        remoteAutomaticResetPolicyStatusIsError = false
        let result = await Task.detached {
            LinuxDevboxMonitor.automaticResetPolicy(settings: settings)
        }.value
        guard generation == remoteAutomaticResetPolicyRequestGeneration,
              settings == linuxDevboxSettings else {
            return
        }
        applyAutomaticResetPolicyResult(result)
    }

    private func updateAutomaticResetPolicy(to enabled: Bool) {
        let settings = linuxDevboxSettings
        guard settings.usesVPSResetAuthority else {
            automaticRateLimitResetRedemption = enabled
            return
        }
        guard settings.hasUsableVPSResetAuthorityTransport,
              remoteAutomaticResetPolicy != nil,
              !remoteAutomaticResetPolicyIsBusy else {
            return
        }

        remoteAutomaticResetPolicyRequestGeneration &+= 1
        let generation = remoteAutomaticResetPolicyRequestGeneration
        remoteAutomaticResetPolicyIsBusy = true
        remoteAutomaticResetPolicyStatus = "Updating VPS automatic-reset policy..."
        remoteAutomaticResetPolicyStatusIsError = false
        Task {
            let mutation = await Task.detached {
                LinuxDevboxMonitor.setAutomaticResetPolicy(
                    settings: settings,
                    enabled: enabled
                )
            }.value
            guard generation == remoteAutomaticResetPolicyRequestGeneration,
                  settings == linuxDevboxSettings else {
                return
            }

            switch mutation {
            case .success(let observation):
                remoteAutomaticResetPolicy = observation
                remoteAutomaticResetPolicyStatus = "VPS policy changed; verifying..."
                let refreshed = await Task.detached {
                    LinuxDevboxMonitor.automaticResetPolicy(settings: settings)
                }.value
                guard generation == remoteAutomaticResetPolicyRequestGeneration,
                      settings == linuxDevboxSettings else {
                    return
                }
                switch refreshed {
                case .success:
                    applyAutomaticResetPolicyResult(refreshed)
                case .failure:
                    remoteAutomaticResetPolicyIsBusy = false
                    remoteAutomaticResetPolicyStatus = "VPS policy changed, but verification failed"
                    remoteAutomaticResetPolicyStatusIsError = true
                }
            case .failure(let failure):
                if failure.disposition == .outcomeUnknown {
                    remoteAutomaticResetPolicy = nil
                }
                remoteAutomaticResetPolicyIsBusy = false
                remoteAutomaticResetPolicyStatus = failure.message
                remoteAutomaticResetPolicyStatusIsError = true
            }
        }
    }

    private func applyAutomaticResetPolicyResult(
        _ result: Result<
            LinuxDevboxAutomaticResetPolicyObservation,
            LinuxDevboxAutomaticResetPolicyFailure
        >
    ) {
        remoteAutomaticResetPolicyIsBusy = false
        switch result {
        case .success(let observation):
            remoteAutomaticResetPolicy = observation
            remoteAutomaticResetPolicyStatusIsError = false
            switch observation.state {
            case .configured:
                let state = observation.automaticRateLimitResetRedemption
                    ? "enabled"
                    : "disabled"
                remoteAutomaticResetPolicyStatus = "VPS automatic-reset policy is \(state)"
            case .missing:
                remoteAutomaticResetPolicyStatus = "VPS policy is not configured; automatic resets are disabled"
            case .invalid:
                remoteAutomaticResetPolicyStatus = "VPS policy is invalid; automatic resets are disabled"
                remoteAutomaticResetPolicyStatusIsError = true
            }
        case .failure(let failure):
            remoteAutomaticResetPolicy = nil
            remoteAutomaticResetPolicyStatus = failure.message
            remoteAutomaticResetPolicyStatusIsError = true
        }
    }

    private var automaticResetAuthorityMode: AutomaticRateLimitResetOwner {
        linuxDevboxSettings.effectiveResetAuthorityMode
    }

    private func updateAutomaticResetAuthorityMode(
        to mode: AutomaticRateLimitResetOwner
    ) {
        guard !linuxDevboxSettings.hasRemoteAuthorityEndpoint || mode == .vpsAuthority else {
            return
        }
        resetAuthorityModeRawValue = mode.rawValue
    }

    private var linuxDevboxSettings: LinuxDevboxMonitorSettings {
        LinuxDevboxMonitorSettings(
            enabled: linuxDevboxMonitorEnabled,
            host: linuxDevboxHost,
            user: linuxDevboxUser,
            sshKeyPath: linuxDevboxSSHKeyPath,
            port: linuxDevboxSSHPort,
            resetAuthorityMode: AutomaticRateLimitResetOwner(
                rawValue: resetAuthorityModeRawValue
            ) ?? .vpsAuthority
        )
    }
}
