import SwiftUI

struct RateLimitResetConfirmationSession: Identifiable, Equatable {
    let presentationId: UUID
    let providerAccountId: String
    let accountEmail: String

    var id: UUID { presentationId }

    static func begin(
        requestedAccount: CodexAccount,
        accounts: [CodexAccount],
        presentations: [UUID: RateLimitResetInventoryPresentation],
        authorization: (UUID) -> RateLimitResetCoordinatorAuthorization,
        now: Date = Date()
    ) -> Self? {
        guard let providerAccountId = requestedAccount.normalizedProviderAccountId,
              let currentAccount = accounts.first(where: {
                  $0.normalizedProviderAccountId == providerAccountId
              }),
              RateLimitResetRedemptionActionPresentation.resolve(
                  account: currentAccount,
                  inventory: presentations[currentAccount.id],
                  coordinatorAuthorization: authorization(currentAccount.id),
                  now: now
              ).isEnabled else {
            return nil
        }

        return Self(
            presentationId: UUID(),
            providerAccountId: providerAccountId,
            accountEmail: currentAccount.email
        )
    }

    func authorizedAccountForSubmission(
        accounts: [CodexAccount],
        presentations: [UUID: RateLimitResetInventoryPresentation],
        authorization: (UUID) -> RateLimitResetCoordinatorAuthorization,
        now: Date = Date()
    ) -> CodexAccount? {
        guard let currentAccount = accounts.first(where: {
            $0.normalizedProviderAccountId == providerAccountId
        }),
              RateLimitResetRedemptionActionPresentation.resolve(
                  account: currentAccount,
                  inventory: presentations[currentAccount.id],
                  coordinatorAuthorization: authorization(currentAccount.id),
                  now: now
              ).isEnabled else {
            return nil
        }
        return currentAccount
    }
}

struct RateLimitResetConfirmationCoordinator {
    private(set) var session: RateLimitResetConfirmationSession?

    var isPresented: Bool { session != nil }

    @discardableResult
    mutating func open(
        requestedAccount: CodexAccount,
        accounts: [CodexAccount],
        presentations: [UUID: RateLimitResetInventoryPresentation],
        authorization: (UUID) -> RateLimitResetCoordinatorAuthorization,
        now: Date = Date()
    ) -> Bool {
        session = RateLimitResetConfirmationSession.begin(
            requestedAccount: requestedAccount,
            accounts: accounts,
            presentations: presentations,
            authorization: authorization,
            now: now
        )
        return isPresented
    }

    mutating func setPresented(
        _ isPresented: Bool,
        presenting presentedSession: RateLimitResetConfirmationSession
    ) {
        if !isPresented {
            dismiss(presenting: presentedSession)
        }
    }

    @discardableResult
    mutating func cancel(
        presenting presentedSession: RateLimitResetConfirmationSession
    ) -> Bool {
        dismiss(presenting: presentedSession)
    }

    @discardableResult
    mutating func dismiss(
        presenting presentedSession: RateLimitResetConfirmationSession
    ) -> Bool {
        guard session == presentedSession else { return false }
        session = nil
        return true
    }

    mutating func dismiss() {
        session = nil
    }

    @discardableResult
    mutating func submit(
        presenting presentedSession: RateLimitResetConfirmationSession,
        accounts: [CodexAccount],
        presentations: [UUID: RateLimitResetInventoryPresentation],
        authorization: (UUID) -> RateLimitResetCoordinatorAuthorization,
        onSubmit: (UUID) -> Void,
        now: Date = Date()
    ) -> Bool {
        guard self.session == presentedSession else { return false }
        session = nil
        guard let account = presentedSession.authorizedAccountForSubmission(
            accounts: accounts,
            presentations: presentations,
            authorization: authorization,
            now: now
        ) else {
            return false
        }
        onSubmit(account.id)
        return true
    }
}

struct PopoverContentView: View {
    @Bindable var manager: AccountManager
    var onAddAccount: () -> Void
    var onForceSwap: (UUID) -> Void
    var onReauthenticate: (UUID) -> Void
    var onRedeemReset: (UUID) -> Void
    var onRefreshResetInventory: (UUID) -> Void
    var resetRedemptionAuthorization: (UUID) -> RateLimitResetCoordinatorAuthorization
    var onOpenSettings: () -> Void
    @State private var resetRedemptionConfirmation = RateLimitResetConfirmationCoordinator()

    private static let relativeFormatter = RelativeDateTimeFormatter()
    private static let popoverWidth: CGFloat = 620
    private static let popoverHeight: CGFloat = 760

    private let columns = [
        GridItem(.adaptive(minimum: 136, maximum: 210), spacing: 8),
    ]

    private var resetRedemptionConfirmationIsPresented: Binding<Bool> {
        let presentedSession = resetRedemptionConfirmation.session
        return Binding(
            get: {
                resetRedemptionConfirmation.session == presentedSession
                    && presentedSession != nil
            },
            set: { isPresented in
                guard let presentedSession else { return }
                resetRedemptionConfirmation.setPresented(
                    isPresented,
                    presenting: presentedSession
                )
            }
        )
    }

    private var resetRedemptionConfirmationTitle: String {
        guard let session = resetRedemptionConfirmation.session else {
            return "Redeem one banked reset?"
        }
        return "Redeem one banked reset for \(session.accountEmail)?"
    }

    private func requestResetRedemptionConfirmation(
        for account: CodexAccount,
        now: Date = Date()
    ) {
        resetRedemptionConfirmation.open(
            requestedAccount: account,
            accounts: manager.accounts,
            presentations: manager.rateLimitResetPresentations,
            authorization: resetRedemptionAuthorization,
            now: now
        )
    }

    private func confirmResetRedemption(
        _ session: RateLimitResetConfirmationSession,
        now: Date = Date()
    ) {
        guard resetRedemptionConfirmation.session == session else { return }
        let submitted = resetRedemptionConfirmation.submit(
            presenting: session,
            accounts: manager.accounts,
            presentations: manager.rateLimitResetPresentations,
            authorization: resetRedemptionAuthorization,
            onSubmit: onRedeemReset,
            now: now
        )
        if !submitted {
            manager.publishActivationNotice(
                "Reset redemption was not submitted because eligibility changed; refresh this account and try again"
            )
        }
    }

    private static func quotaColor(for percent: Double) -> Color {
        switch percent {
        case 50...: return .green
        case 20..<50: return .yellow
        case 5..<20: return .orange
        default: return .red
        }
    }

    static func activationStatusLabel(for state: AccountActivationState) -> String? {
        if state.phase != .confirmed,
           state.discoveredRuntimeCount > 0,
           state.acknowledgedRuntimeCount > 0,
           state.acknowledgedRuntimeCount < state.discoveredRuntimeCount {
            let remaining = state.discoveredRuntimeCount - state.acknowledgedRuntimeCount
            let runtimeWord = remaining == 1 ? "runtime" : "runtimes"
            return "Mac local: \(state.acknowledgedRuntimeCount) of "
                + "\(state.discoveredRuntimeCount) runtimes switched; "
                + "\(remaining) \(runtimeWord) needs restart"
        }

        switch state.phase {
        case .preparing:
            return "Mac local: activation commit pending; account changes paused"
        case .committedDegraded where state.detail == .noLocalRuntime:
            return "Mac local: configured only; start or restart Codex to confirm"
        case .committedDegraded:
            return "Mac local: runtime reload incomplete; restart Codex required"
        case .manualReview where state.detail == .automaticRetryLimitReached:
            return "Mac local: legacy retry state pending recovery"
        case .manualReview where state.detail == .durableConfigurationChanged:
            return "Mac local: stored account changed; verify and retry current account"
        case .manualReview:
            return "Mac local: activation needs manual review; account changes paused"
        case .confirmed:
            return nil
        }
    }

    static func canRetryActivation(_ state: AccountActivationState?) -> Bool {
        guard let state else { return false }
        if state.phase == .committedDegraded { return true }
        return state.phase == .manualReview
            && state.detail?.allowsManualSameTargetRetry == true
    }

    static func macConvergenceLabel(for state: AccountHostConvergenceState) -> String {
        hostConvergenceLabel(host: "Mac", state: state)
    }

    static func vpsConvergenceLabel(for state: AccountHostConvergenceState) -> String {
        hostConvergenceLabel(host: "VPS", state: state)
    }

    static func poolTargetLabel(
        for freshness: ActiveAccountAuthorityFreshness
    ) -> String {
        switch freshness {
        case .current:
            return "Pool Target"
        case .stale:
            return "Pool Target"
        case .unavailable:
            return "Pool Target unavailable"
        }
    }

    private static func hostConvergenceLabel(
        host: String,
        state: AccountHostConvergenceState
    ) -> String {
        switch state {
        case .converged:
            return "\(host) converged"
        case .pending:
            return "\(host) convergence pending"
        case .degraded:
            return "\(host) convergence degraded"
        case .unknown:
            return "\(host) convergence unknown"
        case .unavailable:
            return "\(host) unavailable"
        case .notConfigured:
            return "\(host) not configured"
        }
    }

    private static func hostConvergenceColor(
        for state: AccountHostConvergenceState
    ) -> Color {
        switch state {
        case .converged:
            return .green
        case .pending:
            return .blue
        case .degraded, .unavailable:
            return .orange
        case .unknown, .notConfigured:
            return .secondary
        }
    }

    /// Find the non-active account whose weekly resets soonest (for "Next Available" fallback)
    static func nextWeeklyResetAccount(
        from accounts: [CodexAccount],
        activeProviderAccountId: String? = nil,
        now: Date = Date()
    ) -> (account: CodexAccount, formattedTime: String)? {
        let normalizedActiveProviderAccountId = CodexAccount.normalizedProviderAccountId(
            activeProviderAccountId
        )
        let candidates = accounts
            .compactMap { account -> (CodexAccount, TimeInterval)? in
                guard account.normalizedProviderAccountId != normalizedActiveProviderAccountId,
                      let snapshot = account.realQuotaSnapshot(at: now),
                      let weekly = snapshot.weekly,
                      snapshot.isDenied || weekly.isExhausted else {
                    return nil
                }
                let seconds = weekly.resetsAt.timeIntervalSince(now)
                guard seconds > 0 else { return nil }
                return (account, seconds)
            }
            .sorted { $0.1 < $1.1 }

        guard let best = candidates.first else { return nil }
        let secs = best.1
        let hours = Int(secs) / 3600
        let mins = (Int(secs) % 3600) / 60
        let formatted = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        return (best.0, formatted)
    }

    private var connectionStatus: (icon: String, label: String, color: Color) {
        if manager.accounts.isEmpty {
            return ("bolt.slash.fill", "No accounts — tap + to add one", .secondary)
        }
        let hasQuotaData = manager.accounts.contains { $0.realQuotaSnapshot != nil }
        let hasErrors = manager.accounts.contains { manager.pollingErrors[$0.id] != nil }
        if hasErrors && !hasQuotaData {
            let firstError = manager.accounts.compactMap { manager.pollingErrors[$0.id] }.first ?? "Unknown error"
            return ("exclamationmark.triangle.fill", firstError, .red)
        }
        if !hasQuotaData {
            return ("bolt.badge.clock.fill", "Connecting — waiting for quota data...", .orange)
        }
        let connectedCount = manager.accounts.filter { $0.realQuotaSnapshot != nil }.count
        if hasErrors {
            return ("exclamationmark.triangle.fill", "\(connectedCount)/\(manager.accounts.count) connected — some errors", .orange)
        }
        return ("bolt.fill", "\(connectedCount)/\(manager.accounts.count) accounts connected", .green)
    }

    var body: some View {
        let _ = manager.uiRefreshRevision
        let now = Date()
        let activeAccountReadModel = manager.activeAccountReadModel(at: now)
        let logicalActiveAccount = manager.logicalActiveAccount(
            using: activeAccountReadModel
        )
        let displayedAccounts = manager.sortedAccounts(
            using: activeAccountReadModel,
            now: now
        )
        let resetOverviewItems = RateLimitResetOverviewItem.make(
            accounts: displayedAccounts,
            presentations: manager.rateLimitResetPresentations,
            now: now
        )
        VStack(spacing: 0) {
            HStack {
                Text("CodexSwitch")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let configured = logicalActiveAccount {
                    Text("\(Self.poolTargetLabel(for: activeAccountReadModel.freshness)): \(configured.email)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(Self.poolTargetLabel(
                        for: activeAccountReadModel.freshness
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                }
                VStack(spacing: 1) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gear")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")

                    Text(AppBuildInfo.popoverBuildLabel)
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Connection status banner
            let status = connectionStatus
            HStack(spacing: 6) {
                Image(systemName: status.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(status.color)
                Text(status.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.08))

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    if manager.accounts.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "bolt.slash.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.tertiary)
                            Text("No accounts imported")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("Sign in with your ChatGPT account to get started")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                            Button(action: onAddAccount) {
                                Label("Add Account", systemImage: "plus.circle.fill")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 30)
                        .padding(.horizontal, 20)
                    } else {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(displayedAccounts) { account in
                                AccountCardView(
                                    account: account,
                                    isConfigured: manager.isPoolTarget(
                                        account,
                                        using: activeAccountReadModel
                                    ),
                                    poolTargetFreshness: activeAccountReadModel.freshness,
                                    pollingError: manager.vpsReauthenticationNotice(
                                        for: account,
                                        now: now
                                    ) ?? manager.pollingErrors[account.id],
                                    rateLimitResetPresentation: manager.rateLimitResetPresentations[account.id],
                                    rateLimitResetCoordinatorAuthorization:
                                        resetRedemptionAuthorization(account.id),
                                    onRequestResetRedemption: {
                                        requestResetRedemptionConfirmation(for: account)
                                    },
                                    onRefreshResetInventory: {
                                        onRefreshResetInventory(account.id)
                                    },
                                    onReauthenticate: {
                                        onReauthenticate(account.id)
                                    }
                                ) {
                                    onForceSwap(account.id)
                                }
                            }
                        }
                        .padding(10)
                    }

                    if !resetOverviewItems.isEmpty {
                        Divider()
                        RateLimitResetOverviewView(items: resetOverviewItems)
                    }

                    // Pooled usage meter — aggregate capacity vs Pro
                    if manager.accounts.count > 1 {
                        Divider()
                        PooledUsageMeterView(
                            accounts: manager.accounts,
                            tokenSavingsSummary: manager.tokenSavingsSummary,
                            rateLimitResetPresentations: manager.rateLimitResetPresentations
                        )
                    }

                    // Current account + CLI status + Next up
                    if let active = logicalActiveAccount {
                        let cliStatus = CLIStatusChecker.cachedCLIStatus
                        let desktopStatus = CLIStatusChecker.cachedDesktopStatus
                        let runtimeCurrent = manager.runtimeCurrentAccount?.id == active.id
                        let convergence = manager.hostConvergencePresentation(
                            forPoolTarget: active,
                            now: now
                        )
                        Divider()

                        // One authority target, with host convergence shown globally.
                        HStack(spacing: 6) {
                            Image(systemName: "scope")
                                .foregroundStyle(.green)
                                .font(.system(size: 11))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.poolTargetLabel(
                                    for: activeAccountReadModel.freshness
                                ))
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text(active.email)
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Label(
                                    Self.macConvergenceLabel(for: convergence.mac),
                                    systemImage: "laptopcomputer"
                                )
                                .foregroundStyle(
                                    Self.hostConvergenceColor(for: convergence.mac)
                                )
                                Label(
                                    Self.vpsConvergenceLabel(for: convergence.vps),
                                    systemImage: "server.rack"
                                )
                                .foregroundStyle(
                                    Self.hostConvergenceColor(for: convergence.vps)
                                )
                                .help(manager.linuxDevboxStatus.summary)
                            }
                            .font(.system(size: 8.5, weight: .medium))
                            Spacer()
                            if let snapshot = active.realQuotaSnapshot {
                                switch QuotaSnapshotPresentation(snapshot: snapshot) {
                                case .windows(let rows):
                                    VStack(alignment: .trailing, spacing: 1) {
                                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                            Text("\(Int(row.percent))% \(row.label)")
                                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                                .foregroundStyle(Self.quotaColor(for: row.percent))
                                        }
                                    }
                                case .denied(let message, let rows):
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text(message)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.red)
                                            .lineLimit(1)
                                        if let resetAt = rows.map(\.resetsAt).min(), resetAt > Date() {
                                            Text("Resets \(resetAt, style: .relative)")
                                                .font(.system(size: 8, design: .monospaced))
                                                .foregroundStyle(.orange)
                                                .lineLimit(1)
                                        }
                                    }
                                case .unknown(let message):
                                    Text(message)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 2)

                        let activationStatusLabel = manager.activationNotice
                            ?? manager.activationState.flatMap(Self.activationStatusLabel)
                            ?? "Mac local: configured only; runtime confirmation pending"
                        if !runtimeCurrent {
                            let activationPhase = manager.activationState?.phase
                            let canRetryActivation = Self.canRetryActivation(
                                manager.activationState
                            )
                            HStack(spacing: 4) {
                                Image(systemName: activationPhase == .manualReview
                                    ? "exclamationmark.octagon.fill"
                                    : "arrow.triangle.2.circlepath")
                                    .font(.system(size: 9))
                                    .foregroundStyle(activationPhase == .manualReview ? .red : .orange)
                                Text(activationStatusLabel)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(activationPhase == .manualReview ? .red : .orange)
                                    .lineLimit(2)
                                if canRetryActivation {
                                    Button(action: { onForceSwap(active.id) }) {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Retry pool target convergence")
                                    .accessibilityLabel("Retry pool target convergence")
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.leading, 17)
                            .padding(.bottom, 2)
                        }

                        // CLI connection status (read from cache, never block main thread)
                        HStack(spacing: 4) {
                            Image(systemName: cliStatus.icon)
                                .font(.system(size: 9))
                                .foregroundStyle(runtimeCurrent && cliStatus.isHealthy ? .green : .orange)
                            Text(cliStatus.label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(runtimeCurrent && cliStatus.isHealthy ? .green : .orange)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.leading, 17)
                        .padding(.bottom, 1)
                        if let detail = CLIStatusChecker.cachedCLIStatusDetail {
                            Text(detail)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.orange.opacity(0.85))
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .padding(.horizontal, 12)
                                .padding(.leading, 34)
                                .padding(.bottom, 1)
                        }

                        // Desktop app connection status (read from cache)
                        HStack(spacing: 4) {
                            Image(systemName: desktopStatus.icon)
                                .font(.system(size: 9))
                                .foregroundStyle(runtimeCurrent && desktopStatus.isHealthy ? .green : .secondary)
                            Text(desktopStatus.label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(runtimeCurrent && desktopStatus.isHealthy ? .green : .secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.leading, 17)
                        .padding(.bottom, 2)

                        let desktopPatchLineHealthy = desktopStatus.isHealthy || desktopStatus.patchInstalled
                        HStack(spacing: 4) {
                            Image(systemName: desktopPatchLineHealthy ? "checkmark.seal.fill" : "wrench.and.screwdriver")
                                .font(.system(size: 9))
                                .foregroundStyle(desktopPatchLineHealthy ? .green : .orange)
                            Text(desktopStatus.patchMessage)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(desktopPatchLineHealthy ? .green : .orange)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.leading, 17)
                        .padding(.bottom, 2)
                    }

                    // Next swap preview
                    if manager.activationState?.authorizesAutomaticMutations(at: Date()) == true,
                       let nextUp = SwapEngine.selectOptimalAccount(from: manager.accounts) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.system(size: 11))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Next Up")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 0) {
                                    Text(nextUp.email)
                                        .font(.system(size: 10, weight: .semibold))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let snapshot = nextUp.realQuotaSnapshot,
                                       !snapshot.isDenied,
                                       let window = snapshot.mostUrgentWindow {
                                        let pct = window.effectiveRemainingPercent
                                        Spacer()
                                        Text("\(Int(pct))% \(QuotaWindowDisplay.label(for: window))")
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(Self.quotaColor(for: pct))
                                    }
                                }
                                // Swap reasoning inline
                                Text(SwapEngine.explainSelection(candidate: nextUp, allAccounts: manager.accounts))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                    } else if let nextReset = Self.nextWeeklyResetAccount(
                        from: manager.accounts,
                        activeProviderAccountId: activeAccountReadModel.providerAccountId
                    ) {
                        // All accounts weekly-exhausted — show which resets first
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.orange)
                                .font(.system(size: 11))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Next Available")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 0) {
                                    Text(nextReset.account.email)
                                        .font(.system(size: 10, weight: .semibold))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text(nextReset.formattedTime)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.orange)
                                }
                                if let fiveHour = nextReset.account.realQuotaSnapshot?.fiveHour {
                                    Text("Weekly resets - \(Int(fiveHour.effectiveRemainingPercent))% 5h ready")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 2)
                                        .lineLimit(2)
                                } else {
                                    Text("Weekly window resets")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 2)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                    }

                    // Swap statistics
                    if !manager.swapHistory.isEmpty || manager.accounts.count > 1 {
                        Divider()
                        SwapStatsView(accountCount: manager.accounts.count)
                    }
                }
            }

            Divider()

            HStack {
                if let lastSwap = manager.swapHistory.last {
                    Text("Last swap: \(Self.relativeFormatter.localizedString(for: lastSwap.timestamp, relativeTo: Date()))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No swaps yet")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button(action: onAddAccount) {
                    Label("Add Account", systemImage: "plus.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: Self.popoverWidth, height: Self.popoverHeight)
        .confirmationDialog(
            resetRedemptionConfirmationTitle,
            isPresented: resetRedemptionConfirmationIsPresented,
            titleVisibility: .visible,
            presenting: resetRedemptionConfirmation.session
        ) { session in
            Button("Redeem Oldest Reset", role: .destructive) {
                confirmResetRedemption(session)
            }
            Button("Cancel", role: .cancel) {
                resetRedemptionConfirmation.cancel(presenting: session)
            }
        } message: { _ in
            Text("This spends the oldest-expiring available reset for this account. It does not switch accounts.")
        }
        .onDisappear {
            resetRedemptionConfirmation.dismiss()
        }
    }
}

private struct RateLimitResetOverviewView: View {
    let items: [RateLimitResetOverviewItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Reset expirations", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            ForEach(items) { item in
                RateLimitResetOverviewRow(item: item)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct RateLimitResetOverviewRow: View {
    let item: RateLimitResetOverviewItem

    private static let expirationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: item.urgency.systemImage)
                .foregroundStyle(item.urgency.presentationColor)
            Text(item.accountEmail)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(
                "\(item.urgency.displayName) • \(item.availableCount) • "
                    + Self.expirationFormatter.string(from: item.expiration)
            )
            .foregroundStyle(item.urgency.presentationColor)
            .lineLimit(1)
        }
        .font(.system(size: 9, weight: .medium))
        .rateLimitResetUrgencyPulse(item.urgency)
        .help(
            "\(item.urgency.accessibilityDescription) for \(item.accountEmail). "
                + "Oldest reset expires \(Self.expirationFormatter.string(from: item.expiration))"
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(item.accountEmail), \(item.availableCount) banked resets. "
                + "\(item.urgency.accessibilityDescription). Oldest expires "
                + Self.expirationFormatter.string(from: item.expiration)
        )
    }
}
