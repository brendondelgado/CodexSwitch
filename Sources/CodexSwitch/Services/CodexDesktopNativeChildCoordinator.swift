import Darwin
import Foundation

enum CodexDesktopNativeChildCoordinator {
    static let legacyLabel = "com.codexswitch.desktop-app-server-9223"
    static let legacyEnvironmentVariable = "CODEX_APP_SERVER_WS_URL"

    struct RetirementResult: Sendable, Equatable {
        let attempted: Bool
        let success: Bool
        let message: String
    }

    static func retireLegacyBridgeIfNeeded() {
        let result = retireLegacyBridge()
        SwapLog.append(.debug(
            "DESKTOP_NATIVE_CHILD_MIGRATION attempted=\(result.attempted) success=\(result.success) message=\(result.message)"
        ))
    }

    static func retireLegacyBridge(
        jobLoaded: () -> Bool = { legacyJobIsLoaded() },
        run: (URL, [String], TimeInterval) -> ProcessRunResult = {
            executableURL, arguments, timeout in
            ProcessRunner.run(
                executableURL: executableURL,
                arguments: arguments,
                timeout: timeout
            )
        },
        removeGeneratedFile: (URL) -> Bool = { removeOwnedRegularFile($0) }
    ) -> RetirementResult {
        var attempted = false
        var failures: [String] = []

        let unset = run(
            URL(fileURLWithPath: "/bin/launchctl"),
            ["unsetenv", legacyEnvironmentVariable],
            3
        )
        attempted = true
        if unset.timedOut || unset.terminationStatus != 0 {
            failures.append("could not clear \(legacyEnvironmentVariable)")
        }

        if jobLoaded() {
            let bootout = run(
                URL(fileURLWithPath: "/bin/launchctl"),
                ["bootout", "\(launchDomain())/\(legacyLabel)"],
                5
            )
            if bootout.timedOut || bootout.terminationStatus != 0 {
                failures.append("could not unload the legacy 9223 launch agent")
            }
        }

        for path in legacyGeneratedFiles() where FileManager.default.fileExists(atPath: path.path) {
            if !removeGeneratedFile(path) {
                failures.append("refused to remove unsafe legacy file \(path.path)")
            }
        }

        if failures.isEmpty {
            return RetirementResult(
                attempted: attempted,
                success: true,
                message: "Official ChatGPT native-child routing is enabled"
            )
        }
        return RetirementResult(
            attempted: attempted,
            success: false,
            message: failures.joined(separator: "; ")
        )
    }

    static func legacyGeneratedFiles(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            home.appendingPathComponent(
                "Library/LaunchAgents/\(legacyLabel).plist"
            ),
            home.appendingPathComponent(
                ".codexswitch/bin/codexswitch-desktop-app-server-9223.sh"
            ),
        ]
    }

    static func authorizesFirstAcknowledgementBootstrap(
        binding: CodexReloadBinding,
        arguments: [String]? = nil,
        parentPID: (Int32) -> Int32? = { processParentPID($0) },
        executablePath: (Int32) -> String? = { processExecutablePath($0) },
        signatureStatus: (String) -> CodexDesktopAppSignatureStatus = {
            CodexDesktopAppLocator.signatureStatus(appPath: $0)
        }
    ) -> Bool {
        guard binding.runtimeKind == .officialDesktopStdioChild,
              binding.processIdentity.ownerUID == UInt32(getuid()),
              let runtimeArguments = arguments
                ?? SwapEngine.processArguments(pid: binding.processIdentity.pid),
              SwapEngine.hasOfficialDesktopStdioInvocation(runtimeArguments) else {
            return false
        }

        var current = binding.processIdentity.pid
        var visited: Set<Int32> = []
        var expectedAppPath: String?
        for _ in 0..<12 {
            guard current > 1, visited.insert(current).inserted,
                  let parent = parentPID(current), parent > 0,
                  let path = executablePath(parent),
                  let appPath = topLevelChatGPTAppPath(containing: path) else {
                return false
            }
            if let expectedAppPath, expectedAppPath != appPath {
                return false
            }
            expectedAppPath = appPath
            if path == "\(appPath)/Contents/MacOS/ChatGPT" {
                return signatureStatus(appPath) == .officialOpenAI
            }
            current = parent
        }
        return false
    }

    static func topLevelChatGPTAppPath(containing executablePath: String) -> String? {
        let applicationsPrefix = "/Applications/"
        let contentsMarker = ".app/Contents/"
        guard executablePath.hasPrefix(applicationsPrefix),
              let marker = executablePath.range(of: contentsMarker) else {
            return nil
        }
        let appPath = String(executablePath[..<marker.lowerBound]) + ".app"
        let bundleName = appPath.dropFirst(applicationsPrefix.count)
        guard !bundleName.isEmpty, !bundleName.contains("/") else { return nil }
        return appPath
    }

    private static func legacyJobIsLoaded() -> Bool {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "\(launchDomain())/\(legacyLabel)"],
            timeout: 3
        )
        return !result.timedOut && result.terminationStatus == 0
    }

    private static func processParentPID(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else {
            return nil
        }
        return Int32(info.pbi_ppid)
    }

    private static func processExecutablePath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is not imported by every macOS SDK.
        var buffer = [CChar](repeating: 0, count: 4_096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func removeOwnedRegularFile(_ url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return errno == ENOENT }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid() else {
            return false
        }
        return unlink(url.path) == 0 || errno == ENOENT
    }

    private static func launchDomain() -> String {
        "gui/\(getuid())"
    }
}
