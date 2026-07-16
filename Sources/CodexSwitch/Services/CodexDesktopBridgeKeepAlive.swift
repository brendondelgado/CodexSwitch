import Darwin
import Foundation

enum CodexDesktopBridgeKeepAlive {
    static let label = "com.codexswitch.desktop-app-server-9223"
    static let port: UInt16 = 9223
    static let websocketURL = "ws://127.0.0.1:9223"
    private static let maximumRuntimeBytes: Int64 = 512 * 1024 * 1024
    private static let maximumHelperBytes: Int64 = 128 * 1024 * 1024
    private static let maximumBridgeFileBytes: Int64 = 64 * 1024

    static func installIfNeeded() {
        do {
            let paths = supportPaths()
            try FileManager.default.createDirectory(
                at: paths.binDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: paths.logDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: paths.launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let scriptChanged = try writeIfChanged(
                bridgeScript(launcherPath: paths.launcherURL.path),
                to: paths.scriptURL,
                permissions: 0o755
            )
            let plistChanged = try writeIfChanged(
                launchAgentPlist(
                    scriptPath: paths.scriptURL.path,
                    standardOutputPath: paths.standardOutputURL.path,
                    standardErrorPath: paths.standardErrorURL.path
                ),
                to: paths.launchAgentURL,
                permissions: 0o644
            )

            let environment = ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["setenv", "CODEX_APP_SERVER_WS_URL", websocketURL],
                timeout: 3
            )
            guard !environment.timedOut, environment.terminationStatus == 0 else {
                throw bridgeError("could not publish CODEX_APP_SERVER_WS_URL")
            }

            let loaded = launchAgentIsLoaded()
            guard scriptChanged || plistChanged || !loaded else {
                SwapLog.append(.debug(
                    "DESKTOP_BRIDGE_READY port=\(port) label=\(label)"
                ))
                return
            }

            if loaded {
                _ = ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                    arguments: ["bootout", "\(launchDomain())/\(label)"],
                    timeout: 3
                )
            }

            let bootstrap = ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["bootstrap", launchDomain(), paths.launchAgentURL.path],
                timeout: 5
            )
            guard !bootstrap.timedOut, bootstrap.terminationStatus == 0 else {
                let detail = bootstrap.stderrString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw bridgeError(
                    detail.isEmpty
                        ? "launch agent bootstrap failed"
                        : "launch agent bootstrap failed: \(detail)"
                )
            }
            SwapLog.append(.debug(
                "DESKTOP_BRIDGE_INSTALLED port=\(port) label=\(label)"
            ))
        } catch {
            SwapLog.append(.debug(
                "DESKTOP_BRIDGE_INSTALL_FAILED error=\(error.localizedDescription)"
            ))
        }
    }

    static func bridgeScript(launcherPath: String) -> String {
        """
        #!/bin/zsh
        set -u

        launcher=\(shellQuote(launcherPath))
        log_dir="$HOME/.codexswitch/logs"
        mkdir -p "$log_dir"
        /bin/launchctl setenv CODEX_APP_SERVER_WS_URL \(shellQuote(websocketURL))

        if [[ ! -x "$launcher" ]]; then
          echo "[$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)] desktop bridge launcher missing: $launcher" >> "$log_dir/desktop-app-server-9223.log"
          /bin/sleep 30
          exit 78
        fi

        exec "$launcher" \
          -c features.code_mode_host=true \
          app-server \
          --analytics-default-enabled \
          --listen \(shellQuote(websocketURL))
        """
    }

    static func launchAgentPlist(
        scriptPath: String,
        standardOutputPath: String,
        standardErrorPath: String
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/zsh</string>
                <string>\(xmlEscape(scriptPath))</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>ThrottleInterval</key>
            <integer>5</integer>
            <key>StandardOutPath</key>
            <string>\(xmlEscape(standardOutputPath))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(standardErrorPath))</string>
        </dict>
        </plist>
        """
    }

    static func authorizesFirstAcknowledgementBootstrap(
        binding: CodexReloadBinding,
        socketPort: UInt16
    ) -> Bool {
        let paths = supportPaths()
        guard let route = CodexVersionChecker.installedManagedRuntimeRoute() else {
            return denyBootstrap(binding, reason: "managed_route_unverified")
        }
        guard bridgeFilesAreCurrent(paths) else {
            return denyBootstrap(binding, reason: "bridge_files_changed")
        }
        guard let launchAgentPID = managedLaunchAgentPID() else {
            return denyBootstrap(binding, reason: "launchd_pid_unavailable")
        }
        guard let runtimeFile = verifiedReadOnlyFile(
            at: route.runtimePath,
            expectedSHA256: route.runtimeSHA256,
            maximumBytes: maximumRuntimeBytes
        ) else {
            return denyBootstrap(binding, reason: "runtime_hash_unverified")
        }
        guard let helperFile = verifiedReadOnlyFile(
            at: route.helperPath,
            expectedSHA256: route.helperSHA256,
            maximumBytes: maximumHelperBytes
        ) else {
            return denyBootstrap(binding, reason: "helper_hash_unverified")
        }

        let authorized = firstAcknowledgementBootstrapIsAuthorized(
            binding: binding,
            socketPort: socketPort,
            launchAgentPID: launchAgentPID,
            bridgeFilesCurrent: true,
            route: route,
            runtimeFileIdentity: runtimeFile.identity,
            runtimeDigest: runtimeFile.digest,
            helperDigest: helperFile.digest
        )
        if authorized {
            SwapLog.append(.debug(
                "DESKTOP_BRIDGE_BOOTSTRAP_AUTHORIZED pid=\(binding.processIdentity.pid)"
            ))
        } else {
            return denyBootstrap(binding, reason: "runtime_identity_mismatch")
        }
        return true
    }

    static func firstAcknowledgementBootstrapIsAuthorized(
        binding: CodexReloadBinding,
        socketPort: UInt16,
        launchAgentPID: Int32?,
        bridgeFilesCurrent: Bool,
        route: CodexVersionChecker.ManagedRuntimeRoute?,
        runtimeFileIdentity: DesktopInstallPathIdentity?,
        runtimeDigest: String?,
        helperDigest: String?
    ) -> Bool {
        guard binding.runtimeKind == .externalAppServer,
              socketPort == port,
              binding.processIdentity.ownerUID == UInt32(getuid()),
              launchAgentPID == binding.processIdentity.pid,
              bridgeFilesCurrent,
              let route,
              let runtimeFileIdentity,
              route.managedLauncherPath == supportPaths().launcherURL.path,
              route.runtimePath == binding.processIdentity.executablePath,
              route.runtimePath == binding.kernelExecutableIdentity.canonicalPath,
              runtimeFileIdentity.device == binding.kernelExecutableIdentity.device,
              runtimeFileIdentity.inode == binding.kernelExecutableIdentity.inode,
              runtimeDigest == route.runtimeSHA256,
              helperDigest == route.helperSHA256 else {
            return false
        }
        return true
    }

    static func launchAgentPID(from output: String) -> Int32? {
        let pids = output
            .components(separatedBy: .newlines)
            .compactMap { line -> Int32? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("pid = ") else { return nil }
                return Int32(trimmed.dropFirst("pid = ".count))
            }
            .filter { $0 > 0 }
        return Set(pids).count == 1 ? pids[0] : nil
    }

    private struct Paths {
        let binDirectory: URL
        let logDirectory: URL
        let launcherURL: URL
        let scriptURL: URL
        let launchAgentURL: URL
        let standardOutputURL: URL
        let standardErrorURL: URL
    }

    private static func supportPaths() -> Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexSwitchDirectory = home.appendingPathComponent(
            ".codexswitch",
            isDirectory: true
        )
        let binDirectory = codexSwitchDirectory.appendingPathComponent(
            "bin",
            isDirectory: true
        )
        let logDirectory = codexSwitchDirectory.appendingPathComponent(
            "logs",
            isDirectory: true
        )
        return Paths(
            binDirectory: binDirectory,
            logDirectory: logDirectory,
            launcherURL: home.appendingPathComponent(
                ".local/share/codexswitch/patched-codex/codex"
            ),
            scriptURL: binDirectory.appendingPathComponent(
                "codexswitch-desktop-app-server-9223.sh"
            ),
            launchAgentURL: home
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("\(label).plist"),
            standardOutputURL: logDirectory.appendingPathComponent(
                "desktop-app-server-9223.launchd.out.log"
            ),
            standardErrorURL: logDirectory.appendingPathComponent(
                "desktop-app-server-9223.launchd.err.log"
            )
        )
    }

    private static func launchAgentIsLoaded() -> Bool {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "\(launchDomain())/\(label)"],
            timeout: 3
        )
        return !result.timedOut && result.terminationStatus == 0
    }

    private static func managedLaunchAgentPID() -> Int32? {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "\(launchDomain())/\(label)"],
            timeout: 3
        )
        guard !result.timedOut, result.terminationStatus == 0 else { return nil }
        return launchAgentPID(from: result.stdoutString)
    }

    private static func bridgeFilesAreCurrent(_ paths: Paths) -> Bool {
        regularFileMatches(
            paths.scriptURL,
            expectedData: Data(bridgeScript(launcherPath: paths.launcherURL.path).utf8),
            expectedPermissions: 0o755
        ) && regularFileMatches(
            paths.launchAgentURL,
            expectedData: Data(launchAgentPlist(
                scriptPath: paths.scriptURL.path,
                standardOutputPath: paths.standardOutputURL.path,
                standardErrorPath: paths.standardErrorURL.path
            ).utf8),
            expectedPermissions: 0o644
        )
    }

    private static func regularFileMatches(
        _ url: URL,
        expectedData: Data,
        expectedPermissions: mode_t
    ) -> Bool {
        guard Int64(expectedData.count) <= maximumBridgeFileBytes,
              var metadata = fileMetadata(at: url.path),
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o777 == expectedPermissions,
              let file = try? DesktopPinnedRegularFile(
                  url: url,
                  maximumBytes: maximumBridgeFileBytes
              ),
              file.byteCount == Int64(expectedData.count),
              let data = try? file.read(offset: 0, count: expectedData.count),
              data == expectedData,
              file.verifyPathIdentity() else {
            return false
        }
        metadata = stat()
        return lstat(url.path, &metadata) == 0
            && (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == getuid()
            && metadata.st_mode & 0o777 == expectedPermissions
    }

    private struct VerifiedFile {
        let identity: DesktopInstallPathIdentity
        let digest: String
    }

    private static func verifiedReadOnlyFile(
        at path: String,
        expectedSHA256: String,
        maximumBytes: Int64
    ) -> VerifiedFile? {
        guard var metadata = fileMetadata(at: path),
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o222 == 0,
              let file = try? DesktopPinnedRegularFile(
                  url: URL(fileURLWithPath: path),
                  maximumBytes: maximumBytes
              ),
              file.byteCount > 0,
              let digest = try? file.sha256(isCancelled: { false }),
              digest == expectedSHA256,
              file.verifyPathIdentity() else {
            return nil
        }
        metadata = stat()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o222 == 0 else {
            return nil
        }
        return VerifiedFile(identity: file.identity, digest: digest)
    }

    private static func fileMetadata(at path: String) -> stat? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return metadata
    }

    private static func denyBootstrap(
        _ binding: CodexReloadBinding,
        reason: String
    ) -> Bool {
        SwapLog.append(.debug(
            "DESKTOP_BRIDGE_BOOTSTRAP_DENIED pid=\(binding.processIdentity.pid) reason=\(reason)"
        ))
        return false
    }

    @discardableResult
    private static func writeIfChanged(
        _ contents: String,
        to url: URL,
        permissions: Int
    ) throws -> Bool {
        let data = Data(contents.utf8)
        if let existing = try? Data(contentsOf: url), existing == data {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
            return false
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
        return true
    }

    private static func launchDomain() -> String {
        "gui/\(getuid())"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func bridgeError(_ description: String) -> NSError {
        NSError(
            domain: "CodexDesktopBridgeKeepAlive",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
