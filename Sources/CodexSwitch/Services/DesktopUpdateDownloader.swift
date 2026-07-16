import Darwin
import Foundation

struct DesktopArchiveHTTPResponse: Sendable {
    let statusCode: Int
    let finalURL: URL
    let byteCount: Int64
    let fileIdentity: DesktopInstallPathIdentity
}

protocol DesktopArchiveHTTPTransport: Sendable {
    func download(
        _ request: URLRequest,
        to destination: URL,
        maximumBytes: Int64
    ) async throws -> DesktopArchiveHTTPResponse
}

struct URLSessionDesktopArchiveTransport: DesktopArchiveHTTPTransport {
    func download(
        _ request: URLRequest,
        to destination: URL,
        maximumBytes: Int64
    ) async throws -> DesktopArchiveHTTPResponse {
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(
            destination.deletingLastPathComponent()
        ) else {
            throw DesktopUpdateDownloader.downloaderError(
                "Desktop archive parent contains a symbolic-link component"
            )
        }
        let descriptor = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw DesktopUpdateDownloader.downloaderError(
                "Could not create a no-follow desktop archive file"
            )
        }
        var keepFile = false
        defer {
            _ = close(descriptor)
            if !keepFile { _ = unlink(destination.path) }
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DesktopUpdateDownloader.downloaderError(
                "Desktop archive response was not HTTP"
            )
        }
        guard http.expectedContentLength <= 0
                || http.expectedContentLength <= maximumBytes else {
            throw DesktopUpdateDownloader.downloaderError(
                "Desktop archive response exceeded its byte limit"
            )
        }
        guard http.url?.absoluteString == request.url?.absoluteString else {
            throw DesktopUpdateDownloader.downloaderError(
                "Desktop archive redirected to an unexpected final URL"
            )
        }

        var buffer = [UInt8]()
        buffer.reserveCapacity(64 * 1024)
        var totalBytes: Int64 = 0
        for try await byte in bytes {
            if totalBytes >= maximumBytes {
                throw DesktopUpdateDownloader.downloaderError(
                    "Desktop archive response exceeded its byte limit"
                )
            }
            buffer.append(byte)
            totalBytes += 1
            if buffer.count == 64 * 1024 {
                try writeAll(buffer, to: descriptor)
                buffer.removeAll(keepingCapacity: true)
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty { try writeAll(buffer, to: descriptor) }
        try Task.checkCancellation()
        guard fsync(descriptor) == 0 else {
            throw DesktopUpdateDownloader.downloaderError(
                "Could not synchronize the downloaded desktop archive"
            )
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == totalBytes else {
            throw DesktopUpdateDownloader.downloaderError(
                "Downloaded desktop archive identity was invalid"
            )
        }
        keepFile = true
        return DesktopArchiveHTTPResponse(
            statusCode: http.statusCode,
            finalURL: http.url ?? request.url!,
            byteCount: totalBytes,
            fileIdentity: DesktopInstallPathIdentity(
                device: UInt64(bitPattern: Int64(info.st_dev)),
                inode: UInt64(info.st_ino)
            )
        )
    }

    private func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
        var written = 0
        while written < bytes.count {
            let result = bytes.withUnsafeBytes { storage in
                Darwin.write(
                    descriptor,
                    storage.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else {
                throw DesktopUpdateDownloader.downloaderError(
                    "Could not write the downloaded desktop archive"
                )
            }
            written += result
        }
    }
}

struct DesktopUpdateDownloader: @unchecked Sendable {
    static let minimumFreeSpaceBytes: Int64 = 5 * 1024 * 1024 * 1024
    static let maximumArchiveBytes: Int64 = 3 * 1024 * 1024 * 1024

    let updateRoot: URL
    let temporaryRoot: URL
    let fileManager: FileManager
    let processRunner: DesktopUpdaterProcessRunner
    let transport: any DesktopArchiveHTTPTransport
    let availableCapacity: @Sendable () throws -> Int64
    let extractArchive: (URL, URL, () -> Bool) throws -> Void

    init(
        updateRoot: URL,
        temporaryRoot: URL? = nil,
        fileManager: FileManager = .default,
        processRunner: DesktopUpdaterProcessRunner = DesktopUpdaterProcessRunner(),
        transport: any DesktopArchiveHTTPTransport = URLSessionDesktopArchiveTransport(),
        availableCapacity: (@Sendable () throws -> Int64)? = nil,
        extractArchive: ((URL, URL, () -> Bool) throws -> Void)? = nil
    ) {
        let updateRoot = updateRoot.standardizedFileURL
        self.updateRoot = updateRoot
        self.temporaryRoot = (temporaryRoot
            ?? CodexDesktopPathSecurity.canonicalSystemTemporaryDirectory())
            .standardizedFileURL
        self.fileManager = fileManager
        self.processRunner = processRunner
        self.transport = transport
        self.availableCapacity = availableCapacity ?? {
            try updateRoot.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage ?? 0
        }
        self.extractArchive = extractArchive ?? { archive, destination, isCancelled in
            _ = try processRunner.runChecked(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archive.path, destination.path],
                timeout: 300,
                isCancelled: isCancelled
            )
        }
    }

    func downloadGeneration(
        _ release: CodexDesktopAppRelease,
        now: Date = Date(),
        lifetime: DesktopUpdateOperationLifetime? = nil,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) async throws -> CodexDesktopStagedUpdate {
        guard release.downloadURL.scheme == "https",
              release.downloadURL.host == "persistent.oaistatic.com" else {
            throw Self.downloaderError("The official appcast returned an unexpected download host")
        }
        guard let archiveDigest = release.archiveSHA256,
              archiveDigest.count == 64,
              archiveDigest.allSatisfy(\.isHexDigit),
              release.archiveLength.map({ $0 >= 0 && $0 <= Self.maximumArchiveBytes })
                ?? true else {
            throw DesktopDefinitiveReleaseRejection(
                reason: "The appcast did not provide a supported bounded archive digest",
                reasonClass: .releaseMetadata
            )
        }
        if isCancelled() { throw CancellationError() }
        let availableBytes = try availableCapacity()
        if isCancelled() { throw CancellationError() }
        guard Self.hasEnoughDiskSpace(availableBytes: availableBytes) else {
            throw Self.downloaderError(
                "At least 5 GB of free disk space is required to stage a ChatGPT update"
            )
        }

        if isCancelled() { throw CancellationError() }
        try CodexDesktopPathSecurity.ensureDirectoryExists(
            updateRoot,
            isCancelled: isCancelled
        )
        if isCancelled() { throw CancellationError() }
        let workDirectory = try CodexDesktopTemporaryWorkspace.create(
            in: temporaryRoot,
            prefix: CodexDesktopTemporaryWorkspace.stagePrefix,
            fileManager: fileManager,
            isCancelled: isCancelled
        )
        defer { try? fileManager.removeItem(at: workDirectory) }

        var request = URLRequest(url: release.downloadURL)
        request.timeoutInterval = 900
        request.setValue("CodexSwitch/1.0", forHTTPHeaderField: "User-Agent")
        let archiveDirectory = workDirectory.appendingPathComponent("download", isDirectory: true)
        try CodexDesktopPathSecurity.ensureDirectoryExists(
            archiveDirectory,
            isCancelled: isCancelled
        )
        let archive = archiveDirectory.appendingPathComponent("ChatGPT.app.zip")
        let response = try await transport.download(
            request,
            to: archive,
            maximumBytes: Self.maximumArchiveBytes
        )
        if isCancelled() { throw CancellationError() }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.downloaderError(
                "Desktop download failed with HTTP \(response.statusCode)"
            )
        }
        guard response.finalURL.absoluteString == release.downloadURL.absoluteString,
              response.byteCount <= Self.maximumArchiveBytes else {
            throw Self.downloaderError("Desktop archive response identity was unexpected")
        }
        let retainedArchive = try DesktopPinnedRegularFile(
            url: archive,
            expectedIdentity: response.fileIdentity,
            maximumBytes: Self.maximumArchiveBytes
        )
        try lifetime?.enter(.archiveVerification, isCancelled: isCancelled)
        try DesktopArchiveAuthenticator.verify(
            release: release,
            archive: retainedArchive,
            isCancelled: isCancelled
        )
        if isCancelled() { throw CancellationError() }
        _ = try DesktopZIPArchivePreflight.validate(
            archive: retainedArchive,
            isCancelled: isCancelled
        )
        if isCancelled() { throw CancellationError() }
        let extractedRoot = workDirectory.appendingPathComponent("extract", isDirectory: true)
        if isCancelled() { throw CancellationError() }
        try CodexDesktopPathSecurity.ensureDirectoryExists(
            extractedRoot,
            isCancelled: isCancelled
        )
        guard let archiveGuard = DesktopBundleTreeMutationGuard(appURL: archiveDirectory),
              retainedArchive.verifyPathIdentity() else {
            throw Self.downloaderError("Desktop archive identity changed before extraction")
        }
        if isCancelled() { throw CancellationError() }
        try extractArchive(archive, extractedRoot, isCancelled)
        if isCancelled() { throw CancellationError() }
        guard retainedArchive.verifyPathIdentity(), !archiveGuard.observedMutation() else {
            throw Self.downloaderError("Desktop archive changed during extraction")
        }
        guard let extractedApp = Self.findDesktopApp(
            in: extractedRoot,
            fileManager: fileManager,
            isCancelled: isCancelled
        ) else {
            throw Self.downloaderError(
                "Downloaded ChatGPT \(release.versionLabel) was incomplete"
            )
        }
        if isCancelled() { throw CancellationError() }
        let install = try Self.verifiedInstall(for: release, appURL: extractedApp)
        if isCancelled() { throw CancellationError() }

        let generationIdentifier = UUID().uuidString
        let generationDirectory = CodexDesktopUpdateStorage.generationDirectory(
            in: updateRoot,
            identifier: generationIdentifier
        )
        return try CodexDesktopStagingWorkspace.withTemporaryDirectory(
            in: updateRoot,
            fileManager: fileManager,
            isCancelled: isCancelled
        ) { incoming in
            let incomingApp = incoming.appendingPathComponent(
                extractedApp.lastPathComponent,
                isDirectory: true
            )
            if isCancelled() { throw CancellationError() }
            _ = try processRunner.runChecked(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: [extractedApp.path, incomingApp.path],
                timeout: 300,
                isCancelled: isCancelled
            )
            if isCancelled() { throw CancellationError() }
            try fileManager.moveItem(at: incoming, to: generationDirectory)
            return CodexDesktopStagedUpdate(
                shortVersion: install.shortVersion,
                bundleVersion: install.bundleVersion,
                downloadURL: release.downloadURL,
                appPath: generationDirectory
                    .appendingPathComponent(extractedApp.lastPathComponent)
                    .path,
                stagedAt: now,
                generationIdentifier: generationIdentifier,
                archiveSHA256: release.archiveSHA256,
                archiveLength: release.archiveLength
            )
        }
    }

    static func hasEnoughDiskSpace(availableBytes: Int64) -> Bool {
        availableBytes >= minimumFreeSpaceBytes
    }

    static func metadataMatches(
        _ release: CodexDesktopAppRelease,
        install: CodexDesktopAppInstall
    ) -> Bool {
        release.bundleVersion == install.bundleVersion
            && release.shortVersion == install.shortVersion
    }

    static func verifiedInstall(
        for release: CodexDesktopAppRelease,
        appURL: URL
    ) throws -> CodexDesktopAppInstall {
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(appURL),
              let install = CodexDesktopAppLocator.locate(appPath: appURL.path) else {
            throw DesktopDefinitiveReleaseRejection(
                reason: "Downloaded ChatGPT \(release.versionLabel) was incomplete",
                reasonClass: .bundleStructure
            )
        }
        guard metadataMatches(release, install: install) else {
            throw DesktopDefinitiveReleaseRejection(
                reason: "Downloaded ChatGPT metadata did not match the appcast: expected "
                    + "\(release.versionLabel), bundle reported \(install.versionLabel)",
                reasonClass: .releaseMetadata
            )
        }
        return install
    }

    static func findDesktopApp(
        in root: URL,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> URL? {
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(root) else { return nil }
        let candidates = [
            root.appendingPathComponent("ChatGPT.app"),
            root.appendingPathComponent("ChatGPT/ChatGPT.app"),
            root.appendingPathComponent("Codex.app"),
            root.appendingPathComponent("Codex/Codex.app"),
        ]
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            if isCancelled() { return nil }
            if CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(candidate) {
                return candidate
            }
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var inspected = 0
        for case let url as URL in enumerator {
            if isCancelled() { return nil }
            inspected += 1
            if inspected > 10_000 { return nil }
            if url.lastPathComponent == "ChatGPT.app" || url.lastPathComponent == "Codex.app" {
                guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(url) else {
                    enumerator.skipDescendants()
                    continue
                }
                return url
            }
        }
        return nil
    }

    static func downloaderError(_ message: String) -> NSError {
        NSError(
            domain: "DesktopUpdateDownloader",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
