import CryptoKit
import Darwin
import Foundation

final class DesktopPinnedRegularFile: @unchecked Sendable {
    let url: URL
    let descriptor: Int32
    let identity: DesktopInstallPathIdentity
    let byteCount: Int64

    init(
        url: URL,
        expectedIdentity: DesktopInstallPathIdentity? = nil,
        maximumBytes: Int64
    ) throws {
        let standardizedURL = url.standardizedFileURL
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
        self.url = standardizedURL
        descriptor = openedDescriptor
        identity = openedIdentity
        byteCount = info.st_size
    }

    deinit {
        _ = close(descriptor)
    }

    func verifyPathIdentity() -> Bool {
        var pathInfo = stat()
        var descriptorInfo = stat()
        guard lstat(url.path, &pathInfo) == 0,
              (pathInfo.st_mode & S_IFMT) == S_IFREG,
              fstat(descriptor, &descriptorInfo) == 0 else {
            return false
        }
        return Self.identity(pathInfo) == identity
            && Self.identity(descriptorInfo) == identity
            && descriptorInfo.st_size == byteCount
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

enum DesktopArchiveAuthenticator {
    static func verify(
        release: CodexDesktopAppRelease,
        archive: DesktopPinnedRegularFile,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws {
        guard let expectedDigest = release.archiveSHA256,
              expectedDigest.count == 64,
              expectedDigest.allSatisfy(\.isHexDigit) else {
            throw DesktopDefinitiveReleaseRejection(
                reason: "The appcast did not pin a supported archive SHA-256 digest",
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
        guard actualDigest == expectedDigest.lowercased() else {
            throw DesktopDefinitiveReleaseRejection(
                reason: "The downloaded archive digest did not match the appcast",
                reasonClass: .releaseMetadata
            )
        }
    }
}

enum DesktopZIPArchivePreflight {
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
        for _ in 0..<Int(totalEntries) {
            if isCancelled() { throw CancellationError() }
            guard cursor + 46 <= central.count,
                  central.uint32(at: cursor) == 0x02014b50 else {
                throw archiveError("Archive central directory was malformed")
            }
            let versionMadeBy = central.uint16(at: cursor + 4)
            let flags = central.uint16(at: cursor + 8)
            let method = central.uint16(at: cursor + 10)
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
                  flags & 0x1 == 0,
                  method == 0 || method == 8 else {
                throw archiveError("Archive entry used unsupported or unsafe metadata")
            }

            let nameData = central.subdata(
                in: (cursor + 46)..<(cursor + 46 + nameLength)
            )
            guard let name = String(data: nameData, encoding: .utf8),
                  safeRelativePath(name),
                  paths.insert(name).inserted else {
                throw archiveError("Archive entry path was unsafe or duplicated")
            }
            let hostSystem = versionMadeBy >> 8
            let mode = mode_t(externalAttributes >> 16)
            let fileType = mode & S_IFMT
            if hostSystem == 3 {
                guard fileType == 0 || fileType == S_IFREG || fileType == S_IFDIR else {
                    throw archiveError("Archive contained a link or special file")
                }
                if fileType == S_IFLNK {
                    throw archiveError("Archive contained a symbolic link")
                }
            }
            let isDirectory = name.hasSuffix("/") || fileType == S_IFDIR
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
        return Summary(entryCount: Int(totalEntries), expandedBytes: expandedBytes)
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
