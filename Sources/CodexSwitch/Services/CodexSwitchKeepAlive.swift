import Foundation

enum CodexSwitchKeepAlive {
    private static let label = "com.codexswitch.watchdog"

    static func installIfNeeded() {
        let appPath = Bundle.main.bundleURL.path
        let executablePath = Bundle.main.executableURL?.path
            ?? "\(appPath)/Contents/MacOS/CodexSwitch"

        do {
            let paths = try supportPaths()
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

            let script = watchdogScript(appPath: appPath, executablePath: executablePath)
            try writeIfChanged(script, to: paths.scriptURL, permissions: 0o755)

            let plist = launchAgentPlist(scriptPath: paths.scriptURL.path)
            try writeIfChanged(plist, to: paths.launchAgentURL, permissions: 0o644)

            _ = ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["bootout", launchDomain(), paths.launchAgentURL.path],
                timeout: 2
            )
            let result = ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["bootstrap", launchDomain(), paths.launchAgentURL.path],
                timeout: 5
            )
            if result.terminationStatus == 0 {
                SwapLog.append(.debug("KEEPALIVE_INSTALLED label=\(label)"))
            } else {
                let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                SwapLog.append(.debug("KEEPALIVE_INSTALL_FAILED status=\(result.terminationStatus) error=\(message)"))
            }
        } catch {
            SwapLog.append(.debug("KEEPALIVE_INSTALL_FAILED error=\(error.localizedDescription)"))
        }
    }

    static func disable() {
        do {
            let paths = try supportPaths()
            _ = ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["bootout", launchDomain(), paths.launchAgentURL.path],
                timeout: 2
            )
            try? FileManager.default.removeItem(at: paths.launchAgentURL)
            SwapLog.append(.debug("KEEPALIVE_DISABLED label=\(label)"))
        } catch {
            SwapLog.append(.debug("KEEPALIVE_DISABLE_FAILED error=\(error.localizedDescription)"))
        }
    }

    static func watchdogScript(appPath: String, executablePath: String) -> String {
        """
        #!/bin/zsh
        set -u

        app_path=\(shellQuote(appPath))
        executable_path=\(shellQuote(executablePath))
        log_dir="$HOME/.codexswitch/logs"
        log_file="$log_dir/watchdog.log"
        mkdir -p "$log_dir"

        while true; do
          if ! /usr/bin/pgrep -fx "$executable_path" >/dev/null 2>&1; then
            echo "[$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)] CodexSwitch missing; relaunching $app_path" >> "$log_file"
            /usr/bin/open "$app_path" >/dev/null 2>&1 || true
          fi
          /bin/sleep 10
        done
        """
    }

    static func launchAgentPlist(scriptPath: String) -> String {
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
            <key>StandardOutPath</key>
            <string>\(xmlEscape(NSHomeDirectory()))/.codexswitch/logs/watchdog.launchd.out.log</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(NSHomeDirectory()))/.codexswitch/logs/watchdog.launchd.err.log</string>
        </dict>
        </plist>
        """
    }

    private struct Paths {
        let binDirectory: URL
        let logDirectory: URL
        let scriptURL: URL
        let launchAgentURL: URL
    }

    private static func supportPaths() throws -> Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexSwitchDirectory = home.appendingPathComponent(".codexswitch", isDirectory: true)
        let binDirectory = codexSwitchDirectory.appendingPathComponent("bin", isDirectory: true)
        return Paths(
            binDirectory: binDirectory,
            logDirectory: codexSwitchDirectory.appendingPathComponent("logs", isDirectory: true),
            scriptURL: binDirectory.appendingPathComponent("codexswitch-watchdog.sh"),
            launchAgentURL: home
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("\(label).plist")
        )
    }

    private static func writeIfChanged(_ contents: String, to url: URL, permissions: Int) throws {
        let data = Data(contents.utf8)
        if let existing = try? Data(contentsOf: url), existing == data {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
            return
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
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
}
