import Darwin
import Foundation

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
    let temporaryPath = FileManager.default.temporaryDirectory.path
    let resolvedPath: String
    if let resolved = Darwin.realpath(temporaryPath, nil) {
        defer { Darwin.free(resolved) }
        resolvedPath = String(cString: resolved)
    } else {
        resolvedPath = temporaryPath
    }
    return URL(fileURLWithPath: resolvedPath, isDirectory: true)
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(fileName)
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
