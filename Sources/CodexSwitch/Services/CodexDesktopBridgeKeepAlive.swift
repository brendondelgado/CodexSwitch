import Foundation

enum CodexDesktopBridgeKeepAlive {
    static let label = "com.codexswitch.desktop-app-server-9223"
    static let port: UInt16 = 9223
    static let websocketURL = "ws://127.0.0.1:9223"

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
