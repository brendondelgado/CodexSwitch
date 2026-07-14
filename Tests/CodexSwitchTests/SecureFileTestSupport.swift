import Darwin
import Foundation

private enum SecureTestRootError: Error {
    case invalid(String)
    case posix(path: String, code: Int32)
}

private let canonicalSecureTestBaseURL: URL = {
    do {
        if let configured = ProcessInfo.processInfo.environment["CODEXSWITCH_TEST_TMPDIR"],
           !configured.isEmpty {
            return try validatedSecureTestRoot(
                atPath: configured,
                requirePrivateFinalDirectory: true
            )
        }
        return try validatedSecureTestRoot(
            atPath: "/private/tmp",
            requirePrivateFinalDirectory: false
        )
    } catch {
        preconditionFailure("Could not establish the secure-test root: \(error)")
    }
}()

private func validatedSecureTestRoot(
    atPath path: String,
    requirePrivateFinalDirectory: Bool
) throws -> URL {
    guard path.hasPrefix("/"), path != "/", !path.utf8.contains(0) else {
        throw SecureTestRootError.invalid("the path must be absolute")
    }
    let lexicalComponents = path.split(separator: "/", omittingEmptySubsequences: false)
    guard lexicalComponents.first?.isEmpty == true,
          lexicalComponents.dropFirst().allSatisfy({
              !$0.isEmpty && $0 != "." && $0 != ".."
          }) else {
        throw SecureTestRootError.invalid("the path must already be canonical")
    }
    guard let resolved = Darwin.realpath(path, nil) else {
        throw SecureTestRootError.posix(path: path, code: errno)
    }
    defer { Darwin.free(resolved) }
    let canonicalPath = String(cString: resolved)
    guard canonicalPath == path else {
        throw SecureTestRootError.invalid("the path contains a symbolic-link component")
    }

    var descriptor = Darwin.open(
        "/",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
        throw SecureTestRootError.posix(path: "/", code: errno)
    }
    defer { Darwin.close(descriptor) }

    var rootMetadata = stat()
    guard Darwin.fstat(descriptor, &rootMetadata) == 0,
          secureTestAncestorIsTrusted(rootMetadata) else {
        throw SecureTestRootError.invalid("the filesystem root is not trusted")
    }

    let components = canonicalPath.split(separator: "/", omittingEmptySubsequences: true)
    for (index, component) in components.enumerated() {
        let nextDescriptor = Darwin.openat(
            descriptor,
            String(component),
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard nextDescriptor >= 0 else {
            throw SecureTestRootError.posix(path: canonicalPath, code: errno)
        }

        var metadata = stat()
        let isFinal = index == components.count - 1
        let valid = Darwin.fstat(nextDescriptor, &metadata) == 0
            && secureTestAncestorIsTrusted(metadata)
            && (!isFinal || !requirePrivateFinalDirectory || (
                metadata.st_uid == Darwin.geteuid()
                    && metadata.st_mode & mode_t(0o777) == mode_t(S_IRWXU)
            ))
        guard valid else {
            Darwin.close(nextDescriptor)
            throw SecureTestRootError.invalid("the configured root is not private")
        }

        Darwin.close(descriptor)
        descriptor = nextDescriptor
    }
    return URL(fileURLWithPath: canonicalPath, isDirectory: true)
}

private func secureTestAncestorIsTrusted(_ metadata: stat) -> Bool {
    guard metadata.st_mode & S_IFMT == S_IFDIR else { return false }
    let writableByNonOwner = metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0
    if metadata.st_uid == 0 {
        return !writableByNonOwner || metadata.st_mode & mode_t(S_ISVTX) != 0
    }
    return metadata.st_uid == Darwin.geteuid() && !writableByNonOwner
}

enum SwiftTestingSubprocessError: Error {
    case missingRunner([String])
}

func configureSwiftTestingSubprocess(
    _ process: Process,
    filter: String
) throws {
    let testExecutablePath = CommandLine.arguments.first {
        $0.contains(".xctest/Contents/MacOS/")
    } ?? CommandLine.arguments[0]
    let testExecutable = URL(fileURLWithPath: testExecutablePath)
    guard testExecutable.path.contains(".xctest/Contents/MacOS/") else {
        process.executableURL = testExecutable
        process.arguments = ["--filter", filter]
        return
    }

    var developerDirectories: [String] = []
    if let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
       !configured.isEmpty {
        developerDirectories.append(configured)
    }
    developerDirectories.append("/Library/Developer/CommandLineTools")

    let candidates = developerDirectories.map {
        URL(fileURLWithPath: $0, isDirectory: true)
            .appendingPathComponent("usr/libexec/swift/pm/swiftpm-testing-helper")
    }
    guard let helper = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }) else {
        throw SwiftTestingSubprocessError.missingRunner(candidates.map(\.path))
    }

    process.executableURL = helper
    process.arguments = [
        "--test-bundle-path", testExecutable.path,
        testExecutable.path,
        "--testing-library", "swift-testing",
        "--filter", filter,
    ]
}

func makeSecureTestFileURL(prefix: String, fileName: String) -> URL {
    canonicalSecureTestBaseURL
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(fileName)
}

func makeSecureTestDirectoryURL(prefix: String) throws -> URL {
    precondition(
        !prefix.isEmpty && !prefix.contains("/") && prefix != "." && prefix != "..",
        "Secure-test prefixes must be one path component"
    )
    let directory = canonicalSecureTestBaseURL
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    guard Darwin.mkdir(directory.path, mode_t(S_IRWXU)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let descriptor = Darwin.open(
        directory.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
        let code = errno
        _ = Darwin.rmdir(directory.path)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }

    guard Darwin.fchmod(descriptor, mode_t(S_IRWXU)) == 0 else {
        let code = errno
        _ = Darwin.rmdir(directory.path)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
          metadata.st_mode & S_IFMT == S_IFDIR,
          metadata.st_uid == Darwin.geteuid(),
          metadata.st_mode & mode_t(0o777) == mode_t(S_IRWXU) else {
        _ = Darwin.rmdir(directory.path)
        throw POSIXError(.EACCES)
    }
    return directory
}

func overwriteSecureTestFile(_ data: Data, atPath path: String) throws {
    let descriptor = Darwin.open(path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }

    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(
                descriptor,
                bytes.baseAddress!.advanced(by: offset),
                bytes.count - offset
            )
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: count == 0 ? EIO : errno) ?? .EIO)
            }
        }
    }
    guard Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
