import Foundation
import Testing
@testable import CodexSwitch

private actor DesktopCoordinatorRaceGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private struct DesktopCoordinatorRaceSnapshot: Sendable {
    let periodicCancellationObserved: Bool
    let recoveryOverlapCount: Int
    let installAttemptCount: Int
    let busyInstallCount: Int
}

private actor ManualInstallRaceDesktopUpdateExecutor: CodexDesktopUpdateExecuting {
    private let initialPreparationFinished = DesktopCoordinatorRaceGate()
    private let periodicStarted = DesktopCoordinatorRaceGate()
    private let releasePeriodic = DesktopCoordinatorRaceGate()
    private let periodicFinished = DesktopCoordinatorRaceGate()
    private let installStarted = DesktopCoordinatorRaceGate()
    private let releaseInstall = DesktopCoordinatorRaceGate()

    private var preparationCount = 0
    private var periodicInFlight = false
    private var periodicCancellationObserved = false
    private var recoveryOverlapCount = 0
    private var installAttemptCount = 0
    private var busyInstallCount = 0

    func recoverInterruptedInstall(
        epoch: DesktopUpdateRunEpoch
    ) async throws -> DesktopInstallRecoveryResult {
        if periodicInFlight {
            recoveryOverlapCount += 1
        }
        return .none
    }

    func performStartupMaintenance(
        temporaryRoot: URL,
        now: Date,
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopStartupMaintenanceReport {
        .empty
    }

    func prepareLatestUpdate(
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopUpdatePreparationResult {
        preparationCount += 1
        if preparationCount == 1 {
            await initialPreparationFinished.open()
            return .alreadyStaged(Self.stagedUpdate)
        }

        periodicInFlight = true
        await periodicStarted.open()
        await releasePeriodic.wait()
        periodicCancellationObserved = Task.isCancelled
        periodicInFlight = false
        await periodicFinished.open()
        return .upToDate(
            installedVersion: "stale-installed",
            latestVersion: "stale-latest"
        )
    }

    func installStagedUpdateIfReady(
        epoch: DesktopUpdateRunEpoch
    ) async -> CodexDesktopStagedInstallResult {
        installAttemptCount += 1
        if periodicInFlight {
            busyInstallCount += 1
            await installStarted.open()
            return .deferred("busy because periodic check still owns the updater")
        }

        await installStarted.open()
        await releaseInstall.wait()
        return .installed(
            path: "/Applications/ChatGPT.app",
            release: Self.release,
            transaction: CodexDesktopInstallationTransactionCompletion(
                identifier: 42,
                kind: .stagedUpdate,
                committed: true,
                cleanupPending: false
            ),
            cleanupPending: false
        )
    }

    func waitForInitialPreparation() async {
        await initialPreparationFinished.wait()
    }

    func waitForPeriodicStart() async {
        await periodicStarted.wait()
    }

    func allowPeriodicCompletion() async {
        await releasePeriodic.open()
    }

    func waitForPeriodicCompletion() async {
        await periodicFinished.wait()
    }

    func waitForInstallStart() async {
        await installStarted.wait()
    }

    func allowInstallCompletion() async {
        await releaseInstall.open()
    }

    func snapshot() -> DesktopCoordinatorRaceSnapshot {
        DesktopCoordinatorRaceSnapshot(
            periodicCancellationObserved: periodicCancellationObserved,
            recoveryOverlapCount: recoveryOverlapCount,
            installAttemptCount: installAttemptCount,
            busyInstallCount: busyInstallCount
        )
    }

    private static let release = CodexDesktopAppRelease(
        shortVersion: "26.721.31836",
        bundleVersion: "5828",
        downloadURL: URL(
            string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT.zip"
        )!
    )

    private static let stagedUpdate = CodexDesktopStagedUpdate(
        shortVersion: release.shortVersion,
        bundleVersion: release.bundleVersion,
        downloadURL: release.downloadURL,
        appPath: "/tmp/ChatGPT.app",
        stagedAt: Date(timeIntervalSince1970: 1)
    )
}

@MainActor
private func waitForDesktopUpdatePhase(
    _ phase: CodexDesktopUpdatePresentation.Phase,
    coordinator: CodexDesktopUpdateCoordinator
) async -> Bool {
    for _ in 0..<1_000 {
        if coordinator.presentation.phase == phase {
            return true
        }
        await Task.yield()
    }
    return coordinator.presentation.phase == phase
}

@Suite("Desktop update coordinator race arbitration", .serialized)
struct DesktopUpdateCoordinatorRaceTests {
    @MainActor
    @Test("Manual install settles a cancelled periodic check before installation")
    func manualInstallWaitsForPeriodicCheckSettlement() async {
        let executor = ManualInstallRaceDesktopUpdateExecutor()
        let coordinator = CodexDesktopUpdateCoordinator(
            executor: executor,
            nativeUpdateOwnershipProvider: { nil }
        )
        coordinator.start()

        await executor.waitForInitialPreparation()
        #expect(await waitForDesktopUpdatePhase(.staged, coordinator: coordinator))

        coordinator.checkNow(reason: "periodic")
        await executor.waitForPeriodicStart()

        coordinator.manualInstallRequested(waitingForDesktopQuit: false)
        #expect(coordinator.presentation.phase == .installing)

        let completion = DesktopCoordinatorRaceGate()
        var installedUpdate = false
        var transaction: CodexDesktopInstallationTransactionCompletion?
        coordinator.desktopAppDidTerminate { installed, completedTransaction in
            installedUpdate = installed
            transaction = completedTransaction
            Task {
                await completion.open()
            }
        }

        for _ in 0..<1_000 {
            if await executor.snapshot().installAttemptCount > 0 {
                break
            }
            await Task.yield()
        }
        let blockedSnapshot = await executor.snapshot()
        #expect(blockedSnapshot.installAttemptCount == 0)
        #expect(blockedSnapshot.recoveryOverlapCount == 0)

        await executor.allowPeriodicCompletion()
        await executor.waitForInstallStart()

        let installingSnapshot = await executor.snapshot()
        #expect(installingSnapshot.periodicCancellationObserved)
        #expect(installingSnapshot.recoveryOverlapCount == 0)
        #expect(installingSnapshot.installAttemptCount == 1)
        #expect(installingSnapshot.busyInstallCount == 0)
        #expect(coordinator.presentation.phase == .installing)

        await executor.allowInstallCompletion()
        await completion.wait()

        #expect(installedUpdate)
        #expect(transaction?.committed == true)
        #expect(coordinator.presentation.phase == .installing)
        coordinator.stop()
    }

    @MainActor
    @Test("Cancelled periodic completion cannot overwrite manual activation state")
    func stalePeriodicCompletionDoesNotPublish() async {
        let executor = ManualInstallRaceDesktopUpdateExecutor()
        let coordinator = CodexDesktopUpdateCoordinator(
            executor: executor,
            nativeUpdateOwnershipProvider: { nil }
        )
        coordinator.start()

        await executor.waitForInitialPreparation()
        #expect(await waitForDesktopUpdatePhase(.staged, coordinator: coordinator))

        coordinator.checkNow(reason: "periodic")
        await executor.waitForPeriodicStart()
        coordinator.manualInstallRequested(waitingForDesktopQuit: true)
        #expect(coordinator.presentation.phase == .waitingForQuit)

        await executor.allowPeriodicCompletion()
        await executor.waitForPeriodicCompletion()
        for _ in 0..<100 {
            await Task.yield()
        }

        let snapshot = await executor.snapshot()
        #expect(snapshot.periodicCancellationObserved)
        #expect(snapshot.installAttemptCount == 0)
        #expect(coordinator.presentation.phase == .waitingForQuit)
        #expect(coordinator.presentation.installedVersion != "stale-installed")
        coordinator.stop()
    }
}
