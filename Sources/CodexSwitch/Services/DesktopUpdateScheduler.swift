import Foundation

enum DesktopUpdateVersionPolicy {
    static func isReleaseNewer(
        bundleVersion: String,
        than installedBundleVersion: String
    ) -> Bool {
        if let release = Int(bundleVersion), let installed = Int(installedBundleVersion) {
            return release > installed
        }
        return bundleVersion.compare(
            installedBundleVersion,
            options: .numeric
        ) == .orderedDescending
    }

    static func disposition(
        release: CodexDesktopAppRelease,
        installed: CodexDesktopAppInstall
    ) -> CodexDesktopVersionDisposition {
        isReleaseNewer(bundleVersion: release.bundleVersion, than: installed.bundleVersion)
            ? .updateAvailable
            : .current(installed.versionLabel)
    }
}

struct DesktopUpdateStagingService: @unchecked Sendable {
    let root: URL
    let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
    }

    func prepare(
        release: CodexDesktopAppRelease,
        installed: CodexDesktopAppInstall?,
        now: Date = Date(),
        lifetime: DesktopUpdateOperationLifetime? = nil,
        isCancelled: () -> Bool = { Task.isCancelled },
        fullValidation: (URL, String, String) -> CodexDesktopBundleValidationResult,
        download: () async throws -> CodexDesktopStagedUpdate
    ) async -> CodexDesktopUpdatePreparationResult {
        if isCancelled() { return .deferred("Desktop update check was cancelled") }
        let installedBundleVersion = installed?.bundleVersion

        if let staged = CodexDesktopUpdateStorage.loadAuthoritativeUpdate(
            in: root,
            fileManager: fileManager
        ), installedBundleVersion.map({
            DesktopUpdateVersionPolicy.isReleaseNewer(
                bundleVersion: staged.bundleVersion,
                than: $0
            )
        }) ?? true,
        staged.matches(release) || DesktopUpdateVersionPolicy.isReleaseNewer(
            bundleVersion: staged.bundleVersion,
            than: release.bundleVersion
        ) {
            do {
                try lifetime?.enter(.bundleVerification, isCancelled: isCancelled)
            } catch {
                return .deferred(error.localizedDescription)
            }
            let resolution = CodexDesktopUpdateStorage.resolveAuthoritativeGeneration(
                staged,
                in: root,
                now: now,
                fileManager: fileManager,
                lifetime: lifetime,
                isCancelled: isCancelled,
                fullValidation: fullValidation
            )
            if isCancelled() || resolution == .cancelled {
                return .deferred("Desktop update check was cancelled")
            }
            switch resolution {
            case .reuse(let reusable):
                return .alreadyStaged(reusable)
            case .preserveForRetry(let reason):
                return .deferred(
                    "Preserving staged desktop build \(staged.bundleVersion): \(reason)"
                )
            case .revoke(let reason):
                let reasonClass = DesktopBundleTrustValidator.rejectionClass(
                    for: .invalid(reason)
                ) ?? .bundleStructure
                do {
                    if isCancelled() {
                        return .deferred("Desktop update check was cancelled")
                    }
                    try lifetime?.enter(.rejectionLedger, isCancelled: isCancelled)
                    try CodexDesktopUpdateStorage.recordRejectedRelease(
                        staged.release,
                        reasonClass: reasonClass,
                        in: root,
                        now: now,
                        fileManager: fileManager,
                        isCancelled: isCancelled
                    )
                    if isCancelled() {
                        return .deferred("Desktop update check was cancelled")
                    }
                    _ = try CodexDesktopUpdateStorage.quarantineAuthoritativeUpdate(
                        staged,
                        in: root,
                        fileManager: fileManager,
                        isCancelled: isCancelled
                    )
                } catch {
                    return .failed(
                        "Staged desktop build \(staged.bundleVersion) is invalid (\(reason)), "
                            + "but rejection persistence failed: \(error.localizedDescription)"
                    )
                }
            case .cancelled:
                return .deferred("Desktop update check was cancelled")
            }
        }

        if let installed,
           case .current(let installedVersionLabel) = DesktopUpdateVersionPolicy.disposition(
               release: release,
               installed: installed
            ) {
            if isCancelled() { return .deferred("Desktop update check was cancelled") }
            guard discardObsoleteGenerations(
                installedBundleVersion: installed.bundleVersion,
                isCancelled: isCancelled
            ) else {
                return .deferred("Desktop update check was cancelled")
            }
            return .upToDate(installedVersionLabel)
        }

        if CodexDesktopUpdateStorage.isRejectedRelease(
            release,
            in: root,
            fileManager: fileManager
        ) {
            if isCancelled() { return .deferred("Desktop update check was cancelled") }
            if let pending = CodexDesktopUpdateStorage.loadPendingUpdate(
                in: root,
                fileManager: fileManager
            ), pending.matches(release) {
                _ = try? CodexDesktopUpdateStorage.quarantinePendingUpdate(
                    pending,
                    in: root,
                    fileManager: fileManager,
                    isCancelled: isCancelled
                )
            }
            if isCancelled() { return .deferred("Desktop update check was cancelled") }
            return .failed(
                "Desktop release \(release.versionLabel) was previously rejected definitively"
            )
        }

        do {
            let result = try await CodexDesktopDownloadedGenerationCoordinator.prepare(
                release: release,
                in: root,
                now: now,
                fileManager: fileManager,
                lifetime: lifetime,
                isCancelled: isCancelled,
                fullValidation: fullValidation,
                download: download
            )
            if isCancelled() { return .deferred("Desktop update check was cancelled") }
            switch result {
            case .staged(let staged):
                return .staged(staged)
            case .pendingAssessment(let pending, let reason):
                return .deferred(
                    "Preserving downloaded desktop build \(pending.bundleVersion) "
                        + "pending validation: \(reason)"
                )
            }
        } catch is CancellationError {
            return .deferred("Desktop update check was cancelled")
        } catch let rejection as DesktopDefinitiveReleaseRejection {
            do {
                if isCancelled() {
                    return .deferred("Desktop update check was cancelled")
                }
                try lifetime?.enter(.rejectionLedger, isCancelled: isCancelled)
                try CodexDesktopUpdateStorage.recordRejectedRelease(
                    release,
                    reasonClass: rejection.reasonClass,
                    in: root,
                    now: now,
                    fileManager: fileManager,
                    isCancelled: isCancelled
                )
                return .failed(rejection.reason)
            } catch {
                return .failed(
                    "\(rejection.reason); rejection persistence failed: \(error.localizedDescription)"
                )
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func discardObsoleteGenerations(
        installedBundleVersion: String,
        isCancelled: () -> Bool
    ) -> Bool {
        if let staged = CodexDesktopUpdateStorage.loadAuthoritativeUpdate(
            in: root,
            fileManager: fileManager
        ), !DesktopUpdateVersionPolicy.isReleaseNewer(
            bundleVersion: staged.bundleVersion,
            than: installedBundleVersion
        ) {
            if isCancelled() { return false }
            CodexDesktopUpdateStorage.discardAuthoritativeUpdate(
                staged,
                in: root,
                fileManager: fileManager,
                isCancelled: isCancelled
            )
            if isCancelled() { return false }
        }
        if let pending = CodexDesktopUpdateStorage.loadPendingUpdate(
            in: root,
            fileManager: fileManager
        ), !DesktopUpdateVersionPolicy.isReleaseNewer(
            bundleVersion: pending.bundleVersion,
            than: installedBundleVersion
        ) {
            if isCancelled() { return false }
            CodexDesktopUpdateStorage.discardPendingUpdate(
                pending,
                in: root,
                fileManager: fileManager,
                isCancelled: isCancelled
            )
            if isCancelled() { return false }
        }
        return true
    }
}
