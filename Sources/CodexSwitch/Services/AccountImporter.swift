import Foundation
import Darwin

enum AccountAuthObservationFailure: String, Equatable, Sendable {
    case symlink
    case unsafeAncestor
    case ancestorChanged
    case changedDuringRead
    case notRegularFile
    case wrongOwner
    case wrongMode
    case oversized
    case malformed
    case incompleteCredentials
    case readFailed

    var isRetryableObservationFailure: Bool {
        switch self {
        case .ancestorChanged, .changedDuringRead, .readFailed:
            return true
        default:
            return false
        }
    }
}

enum AccountAuthObservation: Sendable {
    case absent
    case valid(CodexAccount)
    case invalid(AccountAuthObservationFailure)
    case unreadable(AccountAuthObservationFailure)
}

enum AccountImporterError: Error, Equatable {
    case absent
    case invalid(AccountAuthObservationFailure)
    case unreadable(AccountAuthObservationFailure)
}

enum AccountImporter {
    struct TestHooks: Sendable {
        var afterOpeningAncestors: (@Sendable () -> Void)?
        var afterReadingBeforeProof: (@Sendable () -> Void)?

        init(
            afterOpeningAncestors: (@Sendable () -> Void)? = nil,
            afterReadingBeforeProof: (@Sendable () -> Void)? = nil
        ) {
            self.afterOpeningAncestors = afterOpeningAncestors
            self.afterReadingBeforeProof = afterReadingBeforeProof
        }
    }

    private struct OpenedAncestor {
        let parentDescriptor: Int32
        let descriptor: Int32
        let name: String
        let metadata: stat
    }

    static let defaultAuthPath = NSString("~/.codex/auth.json").expandingTildeInPath
    static let maximumAuthBytes = 256 * 1024

    static func importCurrentAccount(from path: String? = nil) throws -> CodexAccount {
        switch observeCurrentAccount(from: path) {
        case .valid(let account):
            return account
        case .absent:
            throw AccountImporterError.absent
        case .invalid(let reason):
            throw AccountImporterError.invalid(reason)
        case .unreadable(let reason):
            throw AccountImporterError.unreadable(reason)
        }
    }

    static func observeCurrentAccount(
        from path: String? = nil,
        testHooks: TestHooks = .init()
    ) -> AccountAuthObservation {
        let filePath = path ?? defaultAuthPath
        guard rawPathIsSafe(filePath) else {
            return .invalid(.unsafeAncestor)
        }
        let standardized = URL(fileURLWithPath: filePath).standardizedFileURL.path
        let components = standardized.split(separator: "/", omittingEmptySubsequences: true)
        guard standardized.hasPrefix("/"),
              !components.isEmpty,
              !components.contains("."),
              !components.contains("..") else {
            return .invalid(.unsafeAncestor)
        }

        let rootDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else { return .unreadable(.readFailed) }
        var descriptors = [rootDescriptor]
        defer {
            for descriptor in descriptors.reversed() {
                Darwin.close(descriptor)
            }
        }
        var ancestors: [OpenedAncestor] = []
        for component in components.dropLast() {
            let name = String(component)
            let parentDescriptor = descriptors.last!
            let descriptor = Darwin.openat(
                parentDescriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                return observationForOpenFailure(
                    parentDescriptor: parentDescriptor,
                    name: name,
                    missingIsAbsent: true
                )
            }
            descriptors.append(descriptor)
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                return .unreadable(.readFailed)
            }
            guard directoryIsTrusted(metadata) else {
                return .invalid(.unsafeAncestor)
            }
            ancestors.append(OpenedAncestor(
                parentDescriptor: parentDescriptor,
                descriptor: descriptor,
                name: name,
                metadata: metadata
            ))
        }

        testHooks.afterOpeningAncestors?()

        let parentDescriptor = descriptors.last!
        let fileName = String(components.last!)
        let descriptor = Darwin.openat(
            parentDescriptor,
            fileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            return observationForOpenFailure(
                parentDescriptor: parentDescriptor,
                name: fileName,
                missingIsAbsent: true
            )
        }
        descriptors.append(descriptor)

        var openedStat = stat()
        guard fstat(descriptor, &openedStat) == 0 else { return .unreadable(.readFailed) }
        if let validationFailure = fileValidationFailure(openedStat) {
            return .invalid(validationFailure)
        }

        var data = Data()
        data.reserveCapacity(Int(openedStat.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return .unreadable(.readFailed)
            }
            guard data.count + count <= maximumAuthBytes else { return .invalid(.oversized) }
            data.append(contentsOf: buffer.prefix(count))
        }

        testHooks.afterReadingBeforeProof?()

        var finalStat = stat()
        guard fstat(descriptor, &finalStat) == 0 else { return .unreadable(.readFailed) }
        guard metadataIsStable(openedStat, finalStat),
              data.count == Int(openedStat.st_size) else {
            return .invalid(.changedDuringRead)
        }
        guard pathBindingMatches(
            parentDescriptor: parentDescriptor,
            name: fileName,
            expected: openedStat
        ) else {
            return .invalid(.changedDuringRead)
        }
        guard ancestors.allSatisfy(ancestorIsStableAndBound) else {
            return .invalid(.ancestorChanged)
        }

        do {
            let account = try accountFromAuthJSON(data)
            guard account.hasCompleteRuntimeCredentials else {
                return .invalid(.incompleteCredentials)
            }
            return .valid(account)
        } catch {
            return .invalid(.malformed)
        }
    }

    private static func rawPathIsSafe(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              !path.utf8.contains(0) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first?.isEmpty == true,
              components.dropFirst().allSatisfy({ component in
                  !component.isEmpty && component != "." && component != ".."
              }) else {
            return false
        }
        return true
    }

    static func accountFromAuthJSON(_ data: Data) throws -> CodexAccount {
        let authFile = try JSONDecoder().decode(AuthFile.self, from: data)
        let email = extractEmail(from: authFile.tokens.idToken) ?? "unknown-\(authFile.tokens.accountId.prefix(8))@imported"

        return CodexAccount(
            email: email,
            accessToken: authFile.tokens.accessToken,
            refreshToken: authFile.tokens.refreshToken,
            idToken: authFile.tokens.idToken,
            accountId: authFile.tokens.accountId,
            lastRefreshed: ISO8601DateFormatter().date(from: authFile.lastRefresh)
        )
    }

    /// Extract email from JWT id_token payload (base64-decoded, no verification)
    private static func extractEmail(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
        // Pad to multiple of 4
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else {
            return nil
        }
        return email
    }

    private static func observationForOpenFailure(
        parentDescriptor: Int32,
        name: String,
        missingIsAbsent: Bool
    ) -> AccountAuthObservation {
        let openError = errno
        if openError == ENOENT, missingIsAbsent { return .absent }
        var metadata = stat()
        if fstatat(parentDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
           metadata.st_mode & S_IFMT == S_IFLNK {
            return .invalid(.symlink)
        }
        return openError == ELOOP
            ? .invalid(.symlink)
            : .unreadable(.readFailed)
    }

    private static func directoryIsTrusted(_ metadata: stat) -> Bool {
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return false }
        let permissions = metadata.st_mode & 0o7777
        if metadata.st_uid == 0 {
            let writableByOthers = permissions & 0o022 != 0
            let sticky = permissions & mode_t(S_ISVTX) != 0
            return !writableByOthers || sticky
        }
        return metadata.st_uid == getuid() && permissions & 0o022 == 0
    }

    private static func fileValidationFailure(
        _ metadata: stat
    ) -> AccountAuthObservationFailure? {
        guard metadata.st_mode & S_IFMT == S_IFREG else { return .notRegularFile }
        guard metadata.st_uid == getuid() else { return .wrongOwner }
        guard metadata.st_mode & 0o777 == 0o600 else { return .wrongMode }
        guard metadata.st_size >= 0, metadata.st_size <= maximumAuthBytes else {
            return .oversized
        }
        return nil
    }

    private static func metadataIsStable(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_uid == after.st_uid
            && before.st_gid == after.st_gid
            && before.st_mode == after.st_mode
            && before.st_nlink == after.st_nlink
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static func directoryIdentityIsStable(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_uid == after.st_uid
            && before.st_gid == after.st_gid
            && before.st_mode == after.st_mode
    }

    private static func pathBindingMatches(
        parentDescriptor: Int32,
        name: String,
        expected: stat
    ) -> Bool {
        var current = stat()
        guard fstatat(parentDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            return false
        }
        return current.st_mode & S_IFMT != S_IFLNK
            && current.st_dev == expected.st_dev
            && current.st_ino == expected.st_ino
    }

    private static func ancestorIsStableAndBound(_ ancestor: OpenedAncestor) -> Bool {
        var final = stat()
        guard fstat(ancestor.descriptor, &final) == 0,
              directoryIdentityIsStable(ancestor.metadata, final),
              directoryIsTrusted(final) else {
            return false
        }
        return pathBindingMatches(
            parentDescriptor: ancestor.parentDescriptor,
            name: ancestor.name,
            expected: ancestor.metadata
        )
    }
}
