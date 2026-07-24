import CryptoKit
import Darwin
import Foundation

final class DesktopPinnedRegularFile: @unchecked Sendable {
    let descriptor: Int32
    let identity: DesktopInstallPathIdentity
    let byteCount: Int64
    private let pathURL: URL?

    var isPrivateSnapshot: Bool {
        pathURL == nil
    }

    init(
        url: URL,
        expectedIdentity: DesktopInstallPathIdentity? = nil,
        maximumBytes: Int64
    ) throws {
        // Foundation rewrites an existing canonical /private/var path through
        // the /var symlink when standardizedFileURL is evaluated. Preserve
        // the caller's canonical path and normalize only lexical components.
        let standardizedURL = CodexDesktopPathSecurity.lexicallyStandardized(url)
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(
            standardizedURL.deletingLastPathComponent()
        ) else {
            throw Self.fileError("Archive parent contains a symbolic-link component")
        }
        let openedDescriptor = open(
            standardizedURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard openedDescriptor >= 0 else {
            throw Self.fileError("Could not open downloaded archive without following links")
        }
        var info = stat()
        guard fstat(openedDescriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= maximumBytes else {
            _ = close(openedDescriptor)
            throw Self.fileError("Downloaded archive is not a bounded regular file")
        }
        let openedIdentity = DesktopInstallPathIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
        guard expectedIdentity == nil || expectedIdentity == openedIdentity else {
            _ = close(openedDescriptor)
            throw Self.fileError("Downloaded archive identity changed before verification")
        }
        descriptor = openedDescriptor
        identity = openedIdentity
        byteCount = info.st_size
        pathURL = standardizedURL
    }

    private init(
        descriptor: Int32,
        identity: DesktopInstallPathIdentity,
        byteCount: Int64
    ) {
        self.descriptor = descriptor
        self.identity = identity
        self.byteCount = byteCount
        pathURL = nil
    }

    deinit {
        _ = close(descriptor)
    }

    static func privateSnapshot(
        copying source: DesktopPinnedRegularFile,
        in directory: URL,
        maximumBytes: Int64,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> DesktopPinnedRegularFile {
        guard maximumBytes >= 0,
              source.byteCount <= maximumBytes,
              source.verifyPathIdentity() else {
            throw fileError("Archive source was invalid before snapshotting")
        }
        if isCancelled() { throw CancellationError() }

        let standardizedDirectory = CodexDesktopPathSecurity.lexicallyStandardized(
            directory
        )
        guard CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(
            standardizedDirectory
        ) else {
            throw fileError("Archive snapshot directory contained a symbolic link")
        }
        let directoryDescriptor = open(
            standardizedDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw fileError("Could not open the archive snapshot directory")
        }
        defer { _ = close(directoryDescriptor) }

        let snapshotName = ".authenticated-\(UUID().uuidString)"
        let cloneResult = snapshotName.withCString {
            fclonefileat(
                source.descriptor,
                directoryDescriptor,
                $0,
                UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)
            )
        }
        guard cloneResult == 0 else {
            throw fileError("Could not create an independent archive snapshot")
        }
        var snapshotIsLinked = true
        defer {
            if snapshotIsLinked {
                _ = snapshotName.withCString {
                    unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }
        if isCancelled() { throw CancellationError() }

        let snapshotDescriptor = snapshotName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard snapshotDescriptor >= 0 else {
            throw fileError("Could not retain the independent archive snapshot")
        }
        var keepSnapshotDescriptor = false
        defer {
            if !keepSnapshotDescriptor { _ = close(snapshotDescriptor) }
        }
        guard snapshotName.withCString({
            unlinkat(directoryDescriptor, $0, 0)
        }) == 0 else {
            throw fileError("Could not make the archive snapshot private")
        }
        snapshotIsLinked = false

        guard fchmod(snapshotDescriptor, S_IRUSR) == 0,
              fchflags(snapshotDescriptor, UInt32(UF_IMMUTABLE)) == 0,
              fsync(snapshotDescriptor) == 0 else {
            throw fileError("Could not freeze the private archive snapshot")
        }
        var info = stat()
        guard fstat(snapshotDescriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == source.byteCount,
              info.st_nlink == 0,
              info.st_uid == geteuid(),
              info.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0,
              info.st_flags & UInt32(UF_IMMUTABLE) != 0,
              fcntl(snapshotDescriptor, F_GETFL) & O_ACCMODE == O_RDONLY else {
            throw fileError("Private archive snapshot did not freeze securely")
        }
        let snapshotIdentity = identity(info)
        guard snapshotIdentity != source.identity,
              source.verifyPathIdentity() else {
            throw fileError("Archive source changed while it was snapshotted")
        }
        keepSnapshotDescriptor = true
        return DesktopPinnedRegularFile(
            descriptor: snapshotDescriptor,
            identity: snapshotIdentity,
            byteCount: info.st_size
        )
    }

    func verifyPathIdentity() -> Bool {
        var descriptorInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              (descriptorInfo.st_mode & S_IFMT) == S_IFREG,
              Self.identity(descriptorInfo) == identity,
              descriptorInfo.st_size == byteCount else {
            return false
        }
        guard let pathURL else {
            return descriptorInfo.st_nlink == 0
                && descriptorInfo.st_uid == geteuid()
                && descriptorInfo.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0
                && descriptorInfo.st_flags & UInt32(UF_IMMUTABLE) != 0
                && fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY
        }
        var pathInfo = stat()
        return lstat(pathURL.path, &pathInfo) == 0
            && (pathInfo.st_mode & S_IFMT) == S_IFREG
            && Self.identity(pathInfo) == identity
    }

    func sha256(isCancelled: () -> Bool = { Task.isCancelled }) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw Self.fileError("Could not seek downloaded archive")
        }
        var hasher = SHA256()
        var bytes = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            if isCancelled() { throw CancellationError() }
            let count = bytes.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress, storage.count)
            }
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw Self.fileError("Could not read downloaded archive")
            }
            hasher.update(data: Data(bytes.prefix(Int(count))))
        }
        guard verifyPathIdentity() else {
            throw Self.fileError("Downloaded archive identity changed during verification")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func withMappedData<Result>(
        _ operation: (Data) throws -> Result
    ) throws -> Result {
        guard verifyPathIdentity() else {
            throw Self.fileError("Downloaded archive identity changed before mapping")
        }
        guard byteCount <= Int64(Int.max) else {
            throw Self.fileError("Downloaded archive was too large to map")
        }
        guard byteCount > 0 else {
            return try operation(Data())
        }
        let length = Int(byteCount)
        guard let baseAddress = mmap(
            nil,
            length,
            PROT_READ,
            MAP_PRIVATE,
            descriptor,
            0
        ), baseAddress != MAP_FAILED else {
            throw Self.fileError("Could not map downloaded archive for verification")
        }
        let mappedData = Data(
            bytesNoCopy: baseAddress,
            count: length,
            deallocator: .custom { pointer, count in
                _ = munmap(pointer, count)
            }
        )
        let result = try operation(mappedData)
        guard verifyPathIdentity() else {
            throw Self.fileError("Downloaded archive identity changed during verification")
        }
        return result
    }

    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0,
              offset <= byteCount,
              Int64(count) <= byteCount - offset else {
            throw Self.fileError("Archive read exceeded the retained file bounds")
        }
        var data = Data(count: count)
        var completed = 0
        while completed < count {
            let result = data.withUnsafeMutableBytes { storage in
                pread(
                    descriptor,
                    storage.baseAddress?.advanced(by: completed),
                    count - completed,
                    offset + Int64(completed)
                )
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else {
                throw Self.fileError("Archive ended before the requested bytes")
            }
            completed += result
        }
        return data
    }

    func standardInputHandle() throws -> FileHandle {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0, lseek(duplicate, 0, SEEK_SET) >= 0 else {
            if duplicate >= 0 { _ = close(duplicate) }
            throw Self.fileError("Could not prepare retained archive input")
        }
        return FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
    }

    private static func identity(_ info: stat) -> DesktopInstallPathIdentity {
        DesktopInstallPathIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }

    private static func fileError(_ message: String) -> NSError {
        NSError(
            domain: "DesktopPinnedRegularFile",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

final class DesktopRetainedFileMutationGuard: @unchecked Sendable {
    private let retainedDescriptor: Int32
    private let queueDescriptor: Int32

    init?(descriptor: Int32) {
        let retainedDescriptor = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard retainedDescriptor >= 0 else { return nil }
        let queueDescriptor = kqueue()
        guard queueDescriptor >= 0 else {
            _ = close(retainedDescriptor)
            return nil
        }
        var change = kevent64_s(
            ident: UInt64(retainedDescriptor),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: UInt32(
                NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE
            ),
            data: 0,
            udata: 0,
            ext: (0, 0)
        )
        guard Darwin.kevent64(
            queueDescriptor,
            &change,
            1,
            nil,
            0,
            0,
            nil
        ) == 0 else {
            _ = close(queueDescriptor)
            _ = close(retainedDescriptor)
            return nil
        }
        self.retainedDescriptor = retainedDescriptor
        self.queueDescriptor = queueDescriptor
    }

    deinit {
        _ = close(queueDescriptor)
        _ = close(retainedDescriptor)
    }

    func observedMutation() -> Bool {
        var event = kevent64_s()
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        return Darwin.kevent64(
            queueDescriptor,
            nil,
            0,
            &event,
            1,
            0,
            &timeout
        ) > 0
    }
}

struct DesktopArchiveAuthenticationEvidence: Equatable, Sendable {
    let contentSHA256: String
    let ed25519Signature: String
    let signingKeyID: String
    let byteCount: Int64
}

enum DesktopArchiveAuthenticator {
    static let openAIProductionPublicKeyBase64 =
        "mNfr1v9t63BfgDtlw4C8lRvSY6uMggIXABDOCi3tS6k="
    static let openAIProductionKeyID =
        "openai-ed25519-9ffe67dd945eba79"

    static func verify(
        release: CodexDesktopAppRelease,
        archive: DesktopPinnedRegularFile,
        trustedEd25519PublicKey: Data? = Data(
            base64Encoded: openAIProductionPublicKeyBase64
        ),
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> DesktopArchiveAuthenticationEvidence {
        let expectedDigest = DesktopArchiveAuthentication.normalizedSHA256(
            release.archiveSHA256
        )
        let expectedSignature = DesktopArchiveAuthentication
            .normalizedEd25519Signature(release.archiveEdSignature)
        guard release.archiveSHA256 == nil || expectedDigest != nil,
              release.archiveEdSignature == nil || expectedSignature != nil else {
            throw DesktopDefinitiveReleaseRejection(
                reason: "The appcast contained a malformed archive authenticator",
                reasonClass: .releaseMetadata
            )
        }
        guard let expectedSignature else {
            throw DesktopDefinitiveReleaseRejection(
                reason: "The appcast did not include OpenAI's archive signature",
                reasonClass: .releaseMetadata
            )
        }
        if let expectedLength = release.archiveLength,
           expectedLength != archive.byteCount {
            throw DesktopDefinitiveReleaseRejection(
                reason: "The downloaded archive length did not match the appcast",
                reasonClass: .releaseMetadata
            )
        }
        let actualDigest = try archive.sha256(isCancelled: isCancelled)
        if let expectedDigest {
            guard actualDigest == expectedDigest else {
                throw DesktopDefinitiveReleaseRejection(
                    reason: "The downloaded archive digest did not match the appcast",
                    reasonClass: .releaseMetadata
                )
            }
        }
        if isCancelled() { throw CancellationError() }
        guard let signature = Data(base64Encoded: expectedSignature),
              let trustedEd25519PublicKey,
              trustedEd25519PublicKey.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: trustedEd25519PublicKey
              ) else {
            throw DesktopDefinitiveReleaseRejection(
                reason: "The pinned archive signing key was unavailable",
                reasonClass: .releaseMetadata
            )
        }
        let signatureIsValid = try archive.withMappedData {
            publicKey.isValidSignature(signature, for: $0)
        }
        if isCancelled() { throw CancellationError() }
        guard signatureIsValid else {
            throw DesktopDefinitiveReleaseRejection(
                reason: "The downloaded archive signature did not match the appcast",
                reasonClass: .releaseMetadata
            )
        }
        return DesktopArchiveAuthenticationEvidence(
            contentSHA256: actualDigest,
            ed25519Signature: expectedSignature,
            signingKeyID: openAIProductionKeyID,
            byteCount: archive.byteCount
        )
    }
}

enum DesktopZIPArchivePreflight {
    private static let maximumSymlinkTargetBytes: UInt64 = 4 * 1024

    struct Limits: Equatable, Sendable {
        let maximumEntries: Int
        let maximumExpandedBytes: UInt64
        let maximumCentralDirectoryBytes: Int
        let maximumCompressionRatio: UInt64

        static let desktopUpdate = Limits(
            maximumEntries: 200_000,
            maximumExpandedBytes: 8 * 1024 * 1024 * 1024,
            maximumCentralDirectoryBytes: 64 * 1024 * 1024,
            maximumCompressionRatio: 500
        )
    }

    struct Summary: Equatable, Sendable {
        let entryCount: Int
        let expandedBytes: UInt64
    }

    private enum ArchiveEntryKind {
        case directory
        case regular
        case symbolicLink
    }

    private struct LocalRecord {
        let byteRange: Range<UInt64>
        let payloadOffset: UInt64
    }

    private enum ExtraFieldLocation {
        case local
        case central
    }

    private struct ValidatedExtraFields: Equatable {
        let oldUnixTimestamps: Data?
    }

    static func validate(
        archive: DesktopPinnedRegularFile,
        limits: Limits = .desktopUpdate,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> Summary {
        guard limits.maximumEntries > 0,
              limits.maximumExpandedBytes > 0,
              limits.maximumCentralDirectoryBytes > 0,
              archive.verifyPathIdentity() else {
            throw archiveError("Archive preflight received an invalid retained file")
        }
        if isCancelled() { throw CancellationError() }
        let tailLength = Int(min(archive.byteCount, 65_557))
        let tailOffset = archive.byteCount - Int64(tailLength)
        let tail = try archive.read(offset: tailOffset, count: tailLength)
        guard let endOffset = lastSignature(0x06054b50, in: tail),
              endOffset + 22 <= tail.count else {
            throw archiveError("Archive end record was missing")
        }
        let diskNumber = tail.uint16(at: endOffset + 4)
        let centralDisk = tail.uint16(at: endOffset + 6)
        let diskEntries = tail.uint16(at: endOffset + 8)
        let totalEntries = tail.uint16(at: endOffset + 10)
        let centralSize = tail.uint32(at: endOffset + 12)
        let centralOffset = tail.uint32(at: endOffset + 16)
        let commentLength = tail.uint16(at: endOffset + 20)
        guard diskNumber == 0,
              centralDisk == 0,
              diskEntries == totalEntries,
              totalEntries != UInt16.max,
              centralSize != UInt32.max,
              centralOffset != UInt32.max,
              endOffset + 22 + Int(commentLength) == tail.count,
              Int(totalEntries) <= limits.maximumEntries,
              Int(centralSize) <= limits.maximumCentralDirectoryBytes,
              UInt64(centralOffset) + UInt64(centralSize) <= UInt64(archive.byteCount) else {
            throw archiveError("Archive directory metadata exceeded its supported bounds")
        }

        let central = try archive.read(
            offset: Int64(centralOffset),
            count: Int(centralSize)
        )
        var cursor = 0
        var expandedBytes: UInt64 = 0
        var paths = Set<String>()
        var comparisonPaths = Set<String>()
        var entryKinds: [String: ArchiveEntryKind] = [:]
        var localRecordRanges: [Range<UInt64>] = []
        var symlinkTargets: [String: String] = [:]
        for _ in 0..<Int(totalEntries) {
            if isCancelled() { throw CancellationError() }
            guard cursor + 46 <= central.count,
                  central.uint32(at: cursor) == 0x02014b50 else {
                throw archiveError("Archive central directory was malformed")
            }
            let versionMadeBy = central.uint16(at: cursor + 4)
            let flags = central.uint16(at: cursor + 8)
            let method = central.uint16(at: cursor + 10)
            let crc32 = central.uint32(at: cursor + 16)
            let compressed = UInt64(central.uint32(at: cursor + 20))
            let expanded = UInt64(central.uint32(at: cursor + 24))
            let nameLength = Int(central.uint16(at: cursor + 28))
            let extraLength = Int(central.uint16(at: cursor + 30))
            let entryCommentLength = Int(central.uint16(at: cursor + 32))
            let diskStart = central.uint16(at: cursor + 34)
            let externalAttributes = central.uint32(at: cursor + 38)
            let localOffset = central.uint32(at: cursor + 42)
            let recordLength = 46 + nameLength + extraLength + entryCommentLength
            guard nameLength > 0,
                  cursor + recordLength <= central.count,
                  diskStart == 0,
                  compressed != UInt64(UInt32.max),
                  expanded != UInt64(UInt32.max),
                  localOffset != UInt32.max,
                  UInt64(localOffset) < UInt64(centralOffset),
                  flags & 0x0009 == 0,
                  flags & ~UInt16(0x0806) == 0,
                  method != 0 || flags & 0x0006 == 0,
                  method == 0 || method == 8 else {
                throw archiveError("Archive entry used unsupported or unsafe metadata")
            }

            let nameData = central.subdata(
                in: (cursor + 46)..<(cursor + 46 + nameLength)
            )
            let centralExtra = central.subdata(
                in: (cursor + 46 + nameLength)..<(
                    cursor + 46 + nameLength + extraLength
                )
            )
            let centralExtraFields = try validateExtraFields(
                centralExtra,
                location: .central
            )
            guard let name = String(data: nameData, encoding: .utf8),
                  safeRelativePath(name),
                  let canonicalPath = canonicalArchivePath(name),
                  paths.insert(canonicalPath).inserted,
                  comparisonPaths.insert(comparisonKey(canonicalPath)).inserted else {
                throw archiveError("Archive entry path was unsafe or duplicated")
            }
            let localRecord = try validateLocalRecord(
                archive: archive,
                localOffset: localOffset,
                centralOffset: centralOffset,
                expectedName: nameData,
                expectedFlags: flags,
                expectedMethod: method,
                expectedCRC32: crc32,
                expectedCompressedBytes: compressed,
                expectedExpandedBytes: expanded,
                expectedExtraFields: centralExtraFields
            )
            localRecordRanges.append(localRecord.byteRange)
            let hostSystem = versionMadeBy >> 8
            let mode = mode_t(externalAttributes >> 16)
            let fileType = hostSystem == 3 ? mode & S_IFMT : 0
            if hostSystem == 3 {
                guard fileType == 0
                        || fileType == S_IFREG
                        || fileType == S_IFDIR
                        || fileType == S_IFLNK else {
                    throw archiveError("Archive contained a special file")
                }
            }
            let isDirectory = name.hasSuffix("/") || fileType == S_IFDIR
            if isDirectory {
                guard compressed == 0, expanded == 0 else {
                    throw archiveError("Archive directory contained a payload")
                }
                entryKinds[canonicalPath] = .directory
            } else if fileType == S_IFLNK {
                entryKinds[canonicalPath] = .symbolicLink
            } else {
                entryKinds[canonicalPath] = .regular
            }
            if fileType == S_IFLNK {
                guard !isDirectory,
                      method == 0,
                      flags & 0x8 == 0,
                      compressed == expanded,
                      expanded > 0,
                      expanded <= maximumSymlinkTargetBytes else {
                    throw archiveError("Archive contained an unsupported symbolic link")
                }
                let target = try storedSymlinkTarget(
                    archive: archive,
                    payloadOffset: localRecord.payloadOffset,
                    expectedCompressedBytes: compressed
                )
                guard let normalizedTarget = normalizedSymlinkTarget(
                    target,
                    from: canonicalPath
                ) else {
                    throw archiveError("Archive symbolic link escaped the app bundle")
                }
                symlinkTargets[canonicalPath] = normalizedTarget
            }
            if !isDirectory {
                let (sum, overflow) = expandedBytes.addingReportingOverflow(expanded)
                guard !overflow, sum <= limits.maximumExpandedBytes else {
                    throw archiveError("Archive expanded bytes exceeded the configured limit")
                }
                expandedBytes = sum
                if expanded > 0 {
                    guard compressed > 0,
                          expanded / compressed <= limits.maximumCompressionRatio else {
                        throw archiveError("Archive entry exceeded the compression-ratio limit")
                    }
                }
            }
            cursor += recordLength
        }
        guard cursor == central.count, archive.verifyPathIdentity() else {
            throw archiveError("Archive changed or had trailing central-directory data")
        }
        try validateLocalRecordGraph(
            localRecordRanges,
            centralOffset: UInt64(centralOffset)
        )
        try validateEntryTree(entryKinds)
        try validateSymlinkGraph(paths: paths, targets: symlinkTargets)
        return Summary(entryCount: Int(totalEntries), expandedBytes: expandedBytes)
    }

    private static func validateLocalRecord(
        archive: DesktopPinnedRegularFile,
        localOffset: UInt32,
        centralOffset: UInt32,
        expectedName: Data,
        expectedFlags: UInt16,
        expectedMethod: UInt16,
        expectedCRC32: UInt32,
        expectedCompressedBytes: UInt64,
        expectedExpandedBytes: UInt64,
        expectedExtraFields: ValidatedExtraFields
    ) throws -> LocalRecord {
        let headerOffset = UInt64(localOffset)
        let centralStart = UInt64(centralOffset)
        guard headerOffset + 30 <= centralStart else {
            throw archiveError("Archive local header was out of bounds")
        }
        let header = try archive.read(offset: Int64(headerOffset), count: 30)
        let localNameLength = UInt64(header.uint16(at: 26))
        let localExtraLength = UInt64(header.uint16(at: 28))
        let nameOffset = headerOffset + 30
        let extraOffset = nameOffset + localNameLength
        let payloadOffset = extraOffset + localExtraLength
        guard header.uint32(at: 0) == 0x04034b50,
              header.uint16(at: 6) == expectedFlags,
              header.uint16(at: 8) == expectedMethod,
              header.uint32(at: 14) == expectedCRC32,
              UInt64(header.uint32(at: 18)) == expectedCompressedBytes,
              UInt64(header.uint32(at: 22)) == expectedExpandedBytes,
              localNameLength == UInt64(expectedName.count),
              payloadOffset <= centralStart,
              expectedCompressedBytes <= centralStart - payloadOffset else {
            throw archiveError(
                "Archive local header did not match its directory entry"
            )
        }
        let localName = try archive.read(
            offset: Int64(nameOffset),
            count: Int(localNameLength)
        )
        guard localName == expectedName else {
            throw archiveError("Archive path changed between local and central headers")
        }
        let localExtra = try archive.read(
            offset: Int64(extraOffset),
            count: Int(localExtraLength)
        )
        let localExtraFields = try validateExtraFields(
            localExtra,
            location: .local
        )
        guard localExtraFields == expectedExtraFields else {
            throw archiveError(
                "Archive extra fields changed between local and central headers"
            )
        }
        let payloadEnd = payloadOffset + expectedCompressedBytes
        return LocalRecord(
            byteRange: headerOffset..<payloadEnd,
            payloadOffset: payloadOffset
        )
    }

    private static func validateExtraFields(
        _ data: Data,
        location: ExtraFieldLocation
    ) throws -> ValidatedExtraFields {
        var cursor = 0
        var identifiers = Set<UInt16>()
        var oldUnixTimestamps: Data?
        while cursor < data.count {
            guard cursor + 4 <= data.count else {
                throw archiveError("Archive extra fields were malformed")
            }
            let identifier = data.uint16(at: cursor)
            let length = Int(data.uint16(at: cursor + 2))
            guard cursor + 4 + length <= data.count else {
                throw archiveError("Archive extra fields were malformed")
            }
            guard identifier != 0x0001 else {
                throw archiveError("Archive used unsupported ZIP64 metadata")
            }
            guard identifiers.insert(identifier).inserted else {
                throw archiveError("Archive repeated an extra-field identifier")
            }
            let payload = data.subdata(
                in: (cursor + 4)..<(cursor + 4 + length)
            )
            switch identifier {
            case 0x5855:
                let expectedLength: Int
                switch location {
                case .local:
                    expectedLength = 12
                case .central:
                    expectedLength = 8
                }
                guard payload.count == expectedLength else {
                    throw archiveError(
                        "Archive used an unsupported old-Unix metadata shape"
                    )
                }
                oldUnixTimestamps = Data(payload.prefix(8))
            default:
                throw archiveError(
                    "Archive used unsupported semantic extra-field metadata"
                )
            }
            cursor += 4 + length
        }
        return ValidatedExtraFields(
            oldUnixTimestamps: oldUnixTimestamps
        )
    }

    private static func validateLocalRecordGraph(
        _ ranges: [Range<UInt64>],
        centralOffset: UInt64
    ) throws {
        let ordered = ranges.sorted {
            if $0.lowerBound == $1.lowerBound {
                return $0.upperBound < $1.upperBound
            }
            return $0.lowerBound < $1.lowerBound
        }
        guard let first = ordered.first,
              first.lowerBound == 0,
              ordered.last?.upperBound == centralOffset else {
            throw archiveError("Archive local records did not cover the payload exactly")
        }
        guard ordered.count > 1 else { return }
        for index in 1..<ordered.count {
            guard ordered[index].lowerBound == ordered[index - 1].upperBound else {
                throw archiveError("Archive local records overlapped or left an unowned gap")
            }
        }
    }

    private static func validateEntryTree(
        _ entryKinds: [String: ArchiveEntryKind]
    ) throws {
        for path in entryKinds.keys {
            let components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            var ancestors: [String] = []
            for component in components.dropLast() {
                ancestors.append(component)
                if let kind = entryKinds[ancestors.joined(separator: "/")],
                   kind != .directory {
                    throw archiveError(
                        "Archive contained a file-directory path conflict"
                    )
                }
            }
        }
    }

    private static func comparisonKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func storedSymlinkTarget(
        archive: DesktopPinnedRegularFile,
        payloadOffset: UInt64,
        expectedCompressedBytes: UInt64
    ) throws -> String {
        let payload = try archive.read(
            offset: Int64(payloadOffset),
            count: Int(expectedCompressedBytes)
        )
        guard let target = String(data: payload, encoding: .utf8),
              !target.isEmpty else {
            throw archiveError("Archive symbolic-link target was not valid UTF-8")
        }
        return target
    }

    private static func normalizedSymlinkTarget(
        _ target: String,
        from sourcePath: String
    ) -> String? {
        guard !target.hasPrefix("/"),
              !target.contains("\\"),
              !target.contains("\0") else { return nil }
        var components = sourcePath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count > 1, let appRoot = components.first else { return nil }
        components.removeLast()
        for component in target.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty { return nil }
            if component == "." { continue }
            if component == ".." {
                guard components.count > 1 else { return nil }
                components.removeLast()
                continue
            }
            if components.isEmpty, component.contains(":") { return nil }
            components.append(String(component))
        }
        guard components.count > 1, components.first == appRoot else { return nil }
        return components.joined(separator: "/")
    }

    private static func validateSymlinkGraph(
        paths: Set<String>,
        targets: [String: String]
    ) throws {
        guard !targets.isEmpty else { return }

        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            var ancestor: [String] = []
            for component in components.dropLast() {
                ancestor.append(component)
                if targets[ancestor.joined(separator: "/")] != nil {
                    throw archiveError(
                        "Archive entry was nested beneath a symbolic link"
                    )
                }
            }
        }

        for source in targets.keys {
            var resolved = targets[source]!
            guard source != resolved, !source.hasPrefix(resolved + "/") else {
                throw archiveError("Archive symbolic links formed a cycle")
            }
            var visited = Set<String>()
            while let link = firstSymlinkPrefix(in: resolved, targets: targets) {
                guard visited.insert(link.path).inserted else {
                    throw archiveError("Archive symbolic links formed a cycle")
                }
                let suffix = resolved.dropFirst(link.path.count)
                resolved = targets[link.path]! + suffix
                guard source != resolved, !source.hasPrefix(resolved + "/") else {
                    throw archiveError("Archive symbolic links formed a cycle")
                }
            }
            guard paths.contains(resolved)
                    || paths.contains(where: { $0.hasPrefix(resolved + "/") }) else {
                throw archiveError("Archive symbolic link had a missing target")
            }
        }
    }

    private static func firstSymlinkPrefix(
        in path: String,
        targets: [String: String]
    ) -> (path: String, target: String)? {
        let components = path.split(separator: "/").map(String.init)
        var prefix: [String] = []
        for component in components {
            prefix.append(component)
            let candidate = prefix.joined(separator: "/")
            if let target = targets[candidate] {
                return (candidate, target)
            }
        }
        return nil
    }

    private static func canonicalArchivePath(_ path: String) -> String? {
        let canonical = path.hasSuffix("/") ? String(path.dropLast()) : path
        return canonical.isEmpty ? nil : canonical
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for (index, component) in components.enumerated() {
            if component == "." || component == ".." { return false }
            if component.isEmpty, index != components.count - 1 { return false }
            if index == 0, component.contains(":") { return false }
        }
        return true
    }

    private static func lastSignature(_ signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        for offset in stride(from: data.count - 4, through: 0, by: -1) {
            if data.uint32(at: offset) == signature { return offset }
        }
        return nil
    }

    private static func archiveError(_ message: String) -> NSError {
        NSError(
            domain: "DesktopZIPArchivePreflight",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
