import CryptoKit
import Foundation
import Security

struct LinuxDevboxMonitorSettings: Sendable {
    let enabled: Bool
    let host: String
    let user: String
    let sshKeyPath: String
    let port: Int

    var isConfigured: Bool {
        enabled && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LinuxDevboxReadiness: Codable, Equatable, Sendable {
    let ready: Bool
    let summary: String
    let accountStoreOk: Bool?
    let authWritable: Bool?
    let daemonRunning: Bool?
    let accountCount: Int?
    let activeEmail: String?
    let readyCandidateCount: Int?
    let issues: [String]?
}

struct LinuxDevboxAccountState: Codable, Sendable {
    let email: String
    let isActive: Bool
    let quotaSnapshot: QuotaSnapshot?
    let planType: String?
    let lastRefreshed: Date?
    let subscriptionRenewsAt: Date?
    let subscriptionExpiresAt: Date?
    let subscriptionWillRenew: Bool?
    let hasActiveSubscription: Bool?
    var runtimeUnusableUntil: Date? = nil
    var runtimeUnusableReason: String? = nil
}

private struct LinuxDevboxAccountStateReport: Codable, Sendable {
    let accounts: [LinuxDevboxAccountState]
}

struct LinuxDevboxStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case notConfigured
        case checking
        case ready
        case notReady
        case failed
    }

    let state: State
    let summary: String
    let activeEmail: String?

    static let notConfigured = LinuxDevboxStatus(
        state: .notConfigured,
        summary: "Linux devbox monitor is not configured",
        activeEmail: nil
    )

    static let checking = LinuxDevboxStatus(
        state: .checking,
        summary: "checking VPS hot-swap readiness...",
        activeEmail: nil
    )

    var isVisible: Bool {
        state != .notConfigured
    }

    var isHealthy: Bool {
        state == .ready
    }

    var shouldShowCheckingPlaceholderBeforeRefresh: Bool {
        state == .notConfigured
    }

    static func shouldSuppressTransientIssue(wasReady: Bool?, consecutiveIssueChecks: Int) -> Bool {
        wasReady == true && consecutiveIssueChecks < 2
    }

    var icon: String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .checking: return "clock.arrow.circlepath"
        case .notReady, .failed: return "exclamationmark.triangle.fill"
        case .notConfigured: return "server.rack"
        }
    }

    var label: String {
        switch state {
        case .ready:
            if let activeEmail {
                return "VPS CLI — Ready: \(activeEmail)"
            }
            return "VPS CLI — Ready"
        case .checking:
            return "VPS CLI — Checking hot-swap readiness"
        case .notReady:
            return "VPS CLI — Not ready: \(summary)"
        case .failed:
            return "VPS CLI — Check failed: \(summary)"
        case .notConfigured:
            return "VPS CLI — Not configured"
        }
    }
}

struct LinuxDevboxMonitorFailure: Error, Equatable, Sendable {
    let message: String
}

enum LinuxDevboxMonitor {
    enum ActiveAccountSyncMode: Equatable, Sendable {
        case statusOnly
        case mirrorVPS
    }

    static let tailscaleBinaryPath = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    static let activeRemoteAccountStatePollInterval: TimeInterval = 5
    static let normalReadinessPollInterval: TimeInterval = 60

    static func credentialSyncFingerprint(accounts: [CodexAccount]) -> String {
        var hasher = SHA256()
        for account in accounts.sorted(by: {
            if $0.accountId != $1.accountId { return $0.accountId < $1.accountId }
            return $0.email.lowercased() < $1.email.lowercased()
        }) {
            updateHash(&hasher, account.accountId)
            updateHash(&hasher, account.email.lowercased())
            updateHash(&hasher, account.accessToken)
            updateHash(&hasher, account.refreshToken)
            updateHash(&hasher, account.idToken)
            updateHash(&hasher, account.isActive ? "active" : "inactive")
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func activeAccountSyncMode(hasActiveRemoteSession: Bool) -> ActiveAccountSyncMode {
        hasActiveRemoteSession ? .mirrorVPS : .statusOnly
    }

    static func shouldRunMacAutoSwap(
        hasActiveRemoteSession: Bool,
        accountMirrorHealthy: Bool,
        localDesktopRuntimeRunning: Bool = false
    ) -> Bool {
        if localDesktopRuntimeRunning {
            return true
        }
        return !(hasActiveRemoteSession && accountMirrorHealthy)
    }

    static func isInteractiveCodexVPSAttachRunning() -> Bool {
        isCodexVPSRemoteSessionRunning()
    }

    static func isCodexVPSRemoteSessionRunning() -> Bool {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "command"],
            timeout: 1
        )
        guard result.terminationStatus == 0, !result.timedOut else { return false }
        return isCodexVPSRemoteSessionRunning(psOutput: result.stdoutString)
    }

    static func isInteractiveCodexVPSAttachRunning(psOutput: String) -> Bool {
        isCodexVPSRemoteSessionRunning(psOutput: psOutput)
    }

    static func isCodexVPSRemoteSessionRunning(psOutput: String) -> Bool {
        psOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .contains { rawLine in
                let line = rawLine.lowercased()
                if line.contains("/usr/bin/ssh") || line.contains("tailscale nc") {
                    return false
                }
                if line.contains("/codex-vps") {
                    return true
                }
                guard line.contains("--remote") else {
                    return false
                }
                let targetsCodexVPS = line.contains("100.95.84.123:8390")
                    || line.contains("127.0.0.1:18390")
                let isCodexClient = line.contains("/codex")
                    || line.contains(" codex ")
                    || line.contains("patched-mac-remote-client")
                return targetsCodexVPS && isCodexClient
            }
    }

    static func shouldRunReadinessCheck(
        now: Date = Date(),
        lastFullCheckAt: Date?,
        hasActiveRemoteSession: Bool,
        force: Bool
    ) -> Bool {
        if force || hasActiveRemoteSession {
            return true
        }
        guard let lastFullCheckAt else {
            return true
        }
        return now.timeIntervalSince(lastFullCheckAt) >= normalReadinessPollInterval
    }

    static func settings(from defaults: UserDefaults = .standard) -> LinuxDevboxMonitorSettings {
        LinuxDevboxMonitorSettings(
            enabled: defaults.bool(forKey: "linuxDevboxMonitorEnabled"),
            host: defaults.string(forKey: "linuxDevboxHost") ?? "",
            user: defaults.string(forKey: "linuxDevboxUser") ?? "",
            sshKeyPath: defaults.string(forKey: "linuxDevboxSSHKeyPath") ?? "",
            port: max(defaults.integer(forKey: "linuxDevboxSSHPort"), 22)
        )
    }

    static func sshArgumentCandidates(settings: LinuxDevboxMonitorSettings) -> [[String]] {
        var base = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ControlPersist=no",
            "-p", "\(settings.port)",
        ]
        if !settings.sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base.append(contentsOf: ["-i", NSString(string: settings.sshKeyPath).expandingTildeInPath])
        }

        let target = "\(settings.user)@\(settings.host)"
        var candidates: [[String]] = []
        if FileManager.default.isExecutableFile(atPath: tailscaleBinaryPath) {
            var proxy = base
            proxy.append(contentsOf: [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ProxyCommand=\(tailscaleBinaryPath) nc %h %p",
                target,
            ])
            candidates.append(proxy)
        }

        var direct = base
        direct.append(target)
        candidates.append(direct)
        return candidates
    }

    private static func runSSH(
        settings: LinuxDevboxMonitorSettings,
        remoteCommand: String,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        var lastResult: ProcessRunResult?
        for candidate in sshArgumentCandidates(settings: settings) {
            let arguments = candidate + [remoteCommand]
            let result = ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: arguments,
                timeout: timeout
            )
            if result.terminationStatus == 0, !result.timedOut {
                return result
            }
            lastResult = result
        }
        return lastResult ?? ProcessRunResult(
            terminationStatus: -1,
            stdout: Data(),
            stderr: Data("No SSH candidates available".utf8),
            timedOut: false
        )
    }

    private static func runSCP(
        settings: LinuxDevboxMonitorSettings,
        localPaths: [String],
        remoteDirectory: String,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        var lastResult: ProcessRunResult?
        for candidate in scpArgumentCandidates(settings: settings) {
            let target = "\(settings.user)@\(settings.host):\(remoteDirectory)/"
            let result = ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/scp"),
                arguments: candidate + localPaths + [target],
                timeout: timeout
            )
            if result.terminationStatus == 0, !result.timedOut {
                return result
            }
            lastResult = result
        }
        return lastResult ?? ProcessRunResult(
            terminationStatus: -1,
            stdout: Data(),
            stderr: Data("No SCP candidates available".utf8),
            timedOut: false
        )
    }

    static func check(settings: LinuxDevboxMonitorSettings) -> Result<LinuxDevboxReadiness, LinuxDevboxMonitorFailure> {
        guard settings.isConfigured else {
            return .failure(LinuxDevboxMonitorFailure(message: "Linux devbox monitor is not configured"))
        }

        let result = runSSH(
            settings: settings,
            remoteCommand: "export PATH=\"$HOME/.local/bin:$PATH\"; codexswitch-cli doctor --json",
            timeout: 20
        )

        guard !result.timedOut else {
            return .failure(LinuxDevboxMonitorFailure(message: "SSH timed out while checking Linux devbox"))
        }
        guard result.terminationStatus == 0 else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(LinuxDevboxMonitorFailure(message: message.isEmpty ? "SSH check failed with status \(result.terminationStatus)" : message))
        }

        do {
            return .success(try JSONDecoder().decode(LinuxDevboxReadiness.self, from: result.stdout))
        } catch {
            return .failure(LinuxDevboxMonitorFailure(message: "Failed to parse Linux devbox readiness JSON: \(error.localizedDescription)"))
        }
    }

    static func pollAccount(
        settings: LinuxDevboxMonitorSettings,
        selector: String
    ) -> Result<String, LinuxDevboxMonitorFailure> {
        guard settings.isConfigured else {
            return .failure(LinuxDevboxMonitorFailure(message: "Linux devbox monitor is not configured"))
        }

        let result = runSSH(
            settings: settings,
            remoteCommand: "export PATH=\"$HOME/.local/bin:$PATH\"; codexswitch-cli poll \(shellQuote(selector))",
            timeout: 25
        )

        guard !result.timedOut else {
            return .failure(LinuxDevboxMonitorFailure(message: "SSH timed out while polling Linux devbox account"))
        }
        guard result.terminationStatus == 0 else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(LinuxDevboxMonitorFailure(message: message.isEmpty ? "SSH poll failed with status \(result.terminationStatus)" : message))
        }
        return .success(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func syncCredentials(
        settings: LinuxDevboxMonitorSettings,
        accounts: [CodexAccount]
    ) -> Result<String, LinuxDevboxMonitorFailure> {
        guard settings.isConfigured else {
            return .failure(LinuxDevboxMonitorFailure(message: "Linux devbox monitor is not configured"))
        }
        guard !accounts.isEmpty else {
            return .failure(LinuxDevboxMonitorFailure(message: "No accounts are available to sync"))
        }

        let remoteDirectory = "/tmp"
        let syncId = UUID().uuidString.lowercased()
        let bundleName = "codexswitch-auto-sync-\(syncId).csbundle"
        let passphraseName = "codexswitch-auto-sync-\(syncId).passphrase"
        let bundlePath = "\(remoteDirectory)/\(bundleName)"
        let passphrasePath = "\(remoteDirectory)/\(passphraseName)"
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswitch-linux-credential-sync-\(syncId)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let passphrase = try randomPassphrase()
            let bundleURL = tempDirectory.appendingPathComponent(bundleName)
            let passphraseURL = tempDirectory.appendingPathComponent(passphraseName)
            let bundle = try LinuxDevboxExportService().makeEncryptedBundle(
                accounts: accounts,
                passphrase: passphrase,
                confirmation: passphrase,
                lifetime: 10 * 60
            )
            try bundle.data.write(to: bundleURL, options: .atomic)
            try passphrase.write(to: passphraseURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundleURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passphraseURL.path)

            let copyResult = runSCP(
                settings: settings,
                localPaths: [bundleURL.path, passphraseURL.path],
                remoteDirectory: remoteDirectory,
                timeout: 30
            )
            guard !copyResult.timedOut else {
                return .failure(LinuxDevboxMonitorFailure(message: "SSH timed out while copying Linux devbox credentials"))
            }
            guard copyResult.terminationStatus == 0 else {
                let message = copyResult.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(LinuxDevboxMonitorFailure(message: message.isEmpty ? "SCP credential sync failed with status \(copyResult.terminationStatus)" : message))
            }

            let importResult = runSSH(
                settings: settings,
                remoteCommand: remoteCredentialSyncCommand(bundlePath: bundlePath, passphrasePath: passphrasePath),
                timeout: 45
            )
            guard !importResult.timedOut else {
                return .failure(LinuxDevboxMonitorFailure(message: "SSH timed out while updating Linux devbox credentials"))
            }
            guard importResult.terminationStatus == 0 else {
                let message = importResult.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(LinuxDevboxMonitorFailure(message: message.isEmpty ? "Linux devbox credential update failed with status \(importResult.terminationStatus)" : message))
            }

            return .success(importResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(LinuxDevboxMonitorFailure(message: "Failed to prepare Linux devbox credential bundle: \(error.localizedDescription)"))
        }
    }

    static func swapAccount(
        settings: LinuxDevboxMonitorSettings,
        selector: String
    ) -> Result<String, LinuxDevboxMonitorFailure> {
        guard settings.isConfigured else {
            return .failure(LinuxDevboxMonitorFailure(message: "Linux devbox monitor is not configured"))
        }

        let result = runSSH(
            settings: settings,
            remoteCommand: remoteSwapCommand(selector: selector),
            timeout: 30
        )

        guard !result.timedOut else {
            return .failure(LinuxDevboxMonitorFailure(message: "SSH timed out while swapping Linux devbox account"))
        }
        guard result.terminationStatus == 0 else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(LinuxDevboxMonitorFailure(message: message.isEmpty ? "SSH swap failed with status \(result.terminationStatus)" : message))
        }
        return .success(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func fetchUsageReport(
        settings: LinuxDevboxMonitorSettings,
        days: Int = 30
    ) -> Result<CodexTokenUsageReport, LinuxDevboxMonitorFailure> {
        guard settings.isConfigured else {
            return .failure(LinuxDevboxMonitorFailure(message: "Linux devbox monitor is not configured"))
        }

        let result = runSSH(
            settings: settings,
            remoteCommand: remoteUsageReportCommand(days: days),
            timeout: 90
        )

        guard !result.timedOut else {
            return .failure(LinuxDevboxMonitorFailure(message: "SSH timed out while fetching Linux devbox token usage"))
        }
        guard result.terminationStatus == 0 else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(LinuxDevboxMonitorFailure(message: message.isEmpty ? "SSH usage check failed with status \(result.terminationStatus)" : message))
        }

        do {
            return .success(try JSONDecoder().decode(CodexTokenUsageReport.self, from: result.stdout))
        } catch {
            return .failure(LinuxDevboxMonitorFailure(message: "Failed to parse Linux devbox token usage JSON: \(error.localizedDescription)"))
        }
    }

    static func fetchAccountStates(
        settings: LinuxDevboxMonitorSettings
    ) -> Result<[LinuxDevboxAccountState], LinuxDevboxMonitorFailure> {
        guard settings.isConfigured else {
            return .failure(LinuxDevboxMonitorFailure(message: "Linux devbox monitor is not configured"))
        }

        let result = runSSH(
            settings: settings,
            remoteCommand: remoteAccountStateCommand(),
            timeout: 20
        )

        guard !result.timedOut else {
            return .failure(LinuxDevboxMonitorFailure(message: "SSH timed out while fetching Linux devbox account state"))
        }
        guard result.terminationStatus == 0 else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(LinuxDevboxMonitorFailure(message: message.isEmpty ? "SSH account state check failed with status \(result.terminationStatus)" : message))
        }

        do {
            return .success(try decodeAccountStates(data: result.stdout))
        } catch {
            return .failure(LinuxDevboxMonitorFailure(message: "Failed to parse Linux devbox account state JSON: \(error.localizedDescription)"))
        }
    }

    static func decodeAccountStates(data: Data) throws -> [LinuxDevboxAccountState] {
        try accountStateDecoder().decode(LinuxDevboxAccountStateReport.self, from: data).accounts
    }

    private static func accountStateDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: value)
            }
            let string = try container.decode(String.self)
            if let value = Double(string) {
                return Date(timeIntervalSinceReferenceDate: value)
            }

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) {
                return date
            }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: string) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected Apple reference-date seconds or ISO8601 date string"
            )
        }
        return decoder
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func remoteCredentialSyncCommand(bundlePath: String, passphrasePath: String) -> String {
        let bundle = shellQuote(bundlePath)
        let passphrase = shellQuote(passphrasePath)
        return """
        chmod 600 \(bundle) \(passphrase) 2>/dev/null || true; export PATH="$HOME/.local/bin:$PATH"; CODEXSWITCH_IMPORT_PASSPHRASE_FILE=\(passphrase) codexswitch-cli update-bundle \(bundle) --ignore-expiry; status=$?; rm -f \(bundle) \(passphrase); if [ "$status" -eq 0 ]; then echo codex_app_server_reload=not_reloaded_credential_sync_only; fi; exit $status
        """
    }

    static func remoteSwapCommand(selector: String) -> String {
        "export PATH=\"$HOME/.local/bin:$PATH\"; codexswitch-cli swap \(shellQuote(selector))"
    }

    static func scpArgumentCandidates(settings: LinuxDevboxMonitorSettings) -> [[String]] {
        var base = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ControlPersist=no",
            "-P", "\(settings.port)",
        ]
        if !settings.sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base.append(contentsOf: ["-i", NSString(string: settings.sshKeyPath).expandingTildeInPath])
        }

        var candidates: [[String]] = []
        if FileManager.default.isExecutableFile(atPath: tailscaleBinaryPath) {
            var proxy = base
            proxy.append(contentsOf: [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ProxyCommand=\(tailscaleBinaryPath) nc %h %p",
            ])
            candidates.append(proxy)
        }

        candidates.append(base)
        return candidates
    }

    private static func randomPassphrase() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw LinuxDevboxExportError.randomBytesFailed
        }
        return Data(bytes).base64EncodedString()
    }

    private static func updateHash(_ hasher: inout SHA256, _ value: String) {
        hasher.update(data: Data(value.utf8))
        hasher.update(data: Data([0]))
    }

    static func remoteAccountStateCommand() -> String {
        """
        python3 - <<'PY'
        import json, pathlib

        home = pathlib.Path.home()
        path = home / ".codexswitch" / "accounts.json"

        def account_value(account, *names):
            for name in names:
                if name in account:
                    return account.get(name)
            return None

        def sanitized(account):
            return {
                "email": account_value(account, "email") or "",
                "isActive": bool(account_value(account, "isActive", "is_active")),
                "quotaSnapshot": account_value(account, "quotaSnapshot", "quota_snapshot"),
                "planType": account_value(account, "planType", "plan_type", "plan"),
                "lastRefreshed": account_value(account, "lastRefreshed", "last_refreshed"),
                "subscriptionRenewsAt": account_value(account, "subscriptionRenewsAt", "subscription_renews_at"),
                "subscriptionExpiresAt": account_value(account, "subscriptionExpiresAt", "subscription_expires_at"),
                "subscriptionWillRenew": account_value(account, "subscriptionWillRenew", "subscription_will_renew"),
                "hasActiveSubscription": account_value(account, "hasActiveSubscription", "has_active_subscription"),
                "runtimeUnusableUntil": account_value(account, "runtimeUnusableUntil", "runtime_unusable_until"),
                "runtimeUnusableReason": account_value(account, "runtimeUnusableReason", "runtime_unusable_reason"),
            }

        if not path.exists():
            print(json.dumps({"accounts": []}))
            raise SystemExit(0)

        raw = json.loads(path.read_text())
        accounts = raw.get("accounts", []) if isinstance(raw, dict) else raw
        accounts = [sanitized(account) for account in accounts if isinstance(account, dict) and account_value(account, "email")]
        print(json.dumps({"accounts": accounts}, separators=(",", ":")))
        PY
        """
    }

    static func remoteUsageReportCommand(days: Int) -> String {
        let safeDays = max(1, min(days, 365))
        return """
        python3 - <<'PY'
        import json, sqlite3, pathlib, time, hashlib, re

        DAYS = \(safeDays)
        REFERENCE = 978307200
        LONG_CONTEXT_THRESHOLD = 272000
        home = pathlib.Path.home()

        def load_accounts():
            path = home / ".codexswitch" / "accounts.json"
            if not path.exists():
                return []
            raw = json.loads(path.read_text())
            return raw.get("accounts", []) if isinstance(raw, dict) else raw

        def token_hashes(accounts):
            hashes = []
            for account in accounts:
                tokens = [
                    account.get("accessToken") or account.get("access_token") or "",
                    account.get("refreshToken") or account.get("refresh_token") or "",
                ]
                for token in tokens:
                    if not token:
                        continue
                    hashes.append(hashlib.sha256(token.encode()).hexdigest()[:12])
            return sorted(set(hashes))

        def field(line, name):
            needle = name + "="
            start = line.find(needle)
            if start < 0:
                return None
            value = line[start + len(needle):]
            if value.startswith('"'):
                value = value[1:]
                end = value.find('"')
                return value[:end] if end >= 0 else None
            end = len(value)
            for idx, char in enumerate(value):
                if char.isspace() or char in ("}", ":", ","):
                    end = idx
                    break
            return value[:end]

        def int_field(line, name):
            value = field(line, name)
            try:
                return int(value) if value is not None else None
            except ValueError:
                return None

        def json_int_field(line, name):
            patterns = [
                r'"' + re.escape(name) + r'"\\s*:\\s*(\\d+)',
                re.escape(name) + r':\\s*(\\d+)',
            ]
            for pattern in patterns:
                match = re.search(pattern, line)
                if match:
                    return int(match.group(1))
            return None

        def json_string_field(line, name):
            match = re.search(r'"' + re.escape(name) + r'"\\s*:\\s*"([^"]+)"', line)
            return match.group(1) if match else None

        def normalize_model(model):
            return (model or "gpt-5.5").split("}")[0].replace("\\n", " ").replace("\\t", " ").strip()

        def parse_json_object_usage(line):
            match = re.search(r'"type"\\s*:\\s*"response\\.completed"', line)
            if not match:
                return None
            start = line.rfind("{", 0, match.start())
            if start < 0:
                return None
            depth = 0
            in_string = False
            escaped = False
            end = None
            for idx in range(start, len(line)):
                char = line[idx]
                if in_string:
                    if escaped:
                        escaped = False
                    elif char == "\\\\":
                        escaped = True
                    elif char == '"':
                        in_string = False
                elif char == '"':
                    in_string = True
                elif char == "{":
                    depth += 1
                elif char == "}":
                    depth -= 1
                    if depth == 0:
                        end = idx
                        break
            if end is None:
                return None
            try:
                root = json.loads(line[start:end + 1])
            except Exception:
                return None
            if not isinstance(root, dict) or root.get("type") != "response.completed":
                return None
            response = root.get("response") or {}
            usage = response.get("usage") or {}
            input_tokens = usage.get("input_tokens")
            output_tokens = usage.get("output_tokens")
            if input_tokens is None or output_tokens is None:
                return None
            input_details = usage.get("input_tokens_details") or {}
            output_details = usage.get("output_tokens_details") or {}
            cached_tokens = input_details.get("cached_tokens")
            if cached_tokens is None:
                cached_tokens = usage.get("cached_tokens") or usage.get("cached_input_tokens") or 0
            reasoning_tokens = output_details.get("reasoning_tokens")
            if reasoning_tokens is None:
                reasoning_tokens = usage.get("reasoning_tokens") or 0
            model = response.get("model") or json_string_field(line, "model")
            return int(input_tokens), int(cached_tokens), int(output_tokens), int(reasoning_tokens), model

        def parse_turn_aggregate_usage(line):
            if "codex.turn.token_usage.input_tokens" not in line:
                return None
            turn_id = field(line, "turn.id")
            input_tokens = int_field(line, "codex.turn.token_usage.input_tokens")
            cached_tokens = int_field(line, "codex.turn.token_usage.cached_input_tokens")
            output_tokens = int_field(line, "codex.turn.token_usage.output_tokens")
            if turn_id is None or input_tokens is None or cached_tokens is None or output_tokens is None:
                return None
            reasoning_tokens = int_field(line, "codex.turn.token_usage.reasoning_output_tokens") or 0
            model = field(line, "model") or field(line, "slug")
            return {
                "kind": "turn",
                "sessionId": field(line, "codexswitch_session") or field(line, "thread_id") or field(line, "thread.id"),
                "turnId": turn_id,
                "timestamp": field(line, "codexswitch_ts") or field(line, "event.timestamp") or "unknown-timestamp",
                "model": normalize_model(model),
                "inputTokens": int(input_tokens),
                "cachedInputTokens": min(int(cached_tokens or 0), int(input_tokens)),
                "outputTokens": int(output_tokens),
                "reasoningTokens": int(reasoning_tokens),
            }

        def parse_token_count_usage(line):
            if '"type":"token_count"' not in line and '"type": "token_count"' not in line:
                return None
            start = line.find("{")
            if start < 0:
                return None
            try:
                root = json.loads(line[start:])
            except Exception:
                return None
            if root.get("type") != "event_msg":
                return None
            payload = root.get("payload") or {}
            if payload.get("type") != "token_count":
                return None
            info = payload.get("info") or {}
            total = info.get("total_token_usage") or {}
            input_tokens = total.get("input_tokens")
            output_tokens = total.get("output_tokens")
            if input_tokens is None or output_tokens is None:
                return None
            cached_tokens = total.get("cached_input_tokens") or 0
            reasoning_tokens = total.get("reasoning_output_tokens") or 0
            return {
                "kind": "session",
                "sessionId": field(line, "codexswitch_session") or field(line, "thread_id") or field(line, "thread.id"),
                "timestamp": root.get("timestamp") or field(line, "codexswitch_ts") or "unknown-timestamp",
                "model": normalize_model(field(line, "codexswitch_model") or field(line, "model")),
                "inputTokens": int(input_tokens),
                "cachedInputTokens": min(int(cached_tokens or 0), int(input_tokens)),
                "outputTokens": int(output_tokens),
                "reasoningTokens": int(reasoning_tokens),
            }

        def usage_lines():
            lines = []
            cutoff = int(time.time() - DAYS * 86400)
            sqlite_path = home / ".codex" / "logs_2.sqlite"
            if sqlite_path.exists():
                conn = sqlite3.connect(sqlite_path)
                rows = conn.execute(
                    '''
                    select 'codexswitch_ts=' || ts || ' codexswitch_target=' || target || ' ' || replace(feedback_log_body, char(10), ' ') from logs
                    where (feedback_log_body like '%response.completed%'
                        or feedback_log_body like '%codex.turn.token_usage.input_tokens%')
                      and ts >= ?
                    order by ts asc
                    ''',
                    (cutoff,),
                ).fetchall()
                lines.extend(row[0] for row in rows)

            session_root = home / ".codex" / "sessions"
            if session_root.exists():
                def model_in(line):
                    try:
                        root = json.loads(line)
                    except Exception:
                        return None
                    payload = root.get("payload") or {}
                    candidates = []
                    if root.get("type") in ("session_meta", "turn_context"):
                        candidates.extend([
                            payload.get("model"),
                            payload.get("model_slug"),
                            payload.get("slug"),
                        ])
                    elif root.get("type") == "event_msg" and payload.get("type") == "token_count":
                        info = payload.get("info") or {}
                        candidates.extend([
                            payload.get("model"),
                            payload.get("model_slug"),
                            payload.get("slug"),
                            info.get("model"),
                            info.get("model_slug"),
                        ])
                    for candidate in candidates:
                        if isinstance(candidate, str) and candidate.strip():
                            return candidate.strip()
                    return None

                def token_count_score(line):
                    try:
                        root = json.loads(line)
                    except Exception:
                        return None
                    if root.get("type") != "event_msg":
                        return None
                    payload = root.get("payload") or {}
                    if payload.get("type") != "token_count":
                        return None
                    total = (payload.get("info") or {}).get("total_token_usage") or {}
                    return (
                        int(total.get("input_tokens") or 0)
                        + int(total.get("output_tokens") or 0)
                        + int(total.get("reasoning_output_tokens") or 0)
                    )

                def tail_lines(path, max_bytes=8 * 1024 * 1024):
                    try:
                        size = path.stat().st_size
                        with path.open("rb") as handle:
                            if size > max_bytes:
                                handle.seek(size - max_bytes)
                                handle.readline()
                            data = handle.read()
                    except OSError:
                        return []
                    return data.decode("utf-8", errors="ignore").splitlines()

                def session_id_for(path):
                    matches = re.findall(
                        r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
                        path.stem,
                        re.I,
                    )
                    return matches[-1] if matches else path.stem

                for path in sorted(session_root.rglob("*.jsonl")):
                    try:
                        if path.stat().st_mtime < cutoff:
                            continue
                    except OSError:
                        continue
                    session_id = session_id_for(path)
                    model = "gpt-5.5"
                    best_line = None
                    best_score = -1
                    for raw_line in tail_lines(path):
                        found_model = model_in(raw_line)
                        if found_model:
                            model = found_model
                        if '"type":"token_count"' not in raw_line and '"type": "token_count"' not in raw_line:
                            continue
                        score = token_count_score(raw_line)
                        if score is not None and score >= best_score:
                            best_score = score
                            best_line = raw_line.strip()
                    if best_line:
                        lines.append(f"codexswitch_session={session_id} codexswitch_model={model} " + best_line)
            return lines

        by_model = {}
        response_seen = set()
        response_events = []
        turn_aggregates = {}
        session_totals = {}
        first_event_at = None

        def add_usage(event):
            global first_event_at
            timestamp = event["timestamp"]
            model = event["model"]
            input_tokens = event["inputTokens"]
            cached_tokens = event["cachedInputTokens"]
            output_tokens = event["outputTokens"]
            reasoning_tokens = event["reasoningTokens"]
            try:
                event_seconds = float(timestamp)
                first_event_at = event_seconds if first_event_at is None else min(first_event_at, event_seconds)
            except ValueError:
                pass
            usage = by_model.setdefault(model, {
                "model": model,
                "inputTokens": 0,
                "cachedInputTokens": 0,
                "outputTokens": 0,
                "reasoningTokens": 0,
                "completionCount": 0,
                "longContextInputTokens": 0,
                "longContextCachedInputTokens": 0,
                "longContextOutputTokens": 0,
            })
            usage["inputTokens"] += input_tokens
            usage["cachedInputTokens"] += cached_tokens
            usage["outputTokens"] += output_tokens
            usage["reasoningTokens"] += reasoning_tokens
            usage["completionCount"] += 1
            if event.get("kind") == "response" and input_tokens > LONG_CONTEXT_THRESHOLD and model.lower() in ("gpt-5.5", "gpt-5.4"):
                usage["longContextInputTokens"] += input_tokens
                usage["longContextCachedInputTokens"] += cached_tokens
                usage["longContextOutputTokens"] += output_tokens

        def add_long_context_pricing(event):
            model = event["model"]
            input_tokens = event["inputTokens"]
            cached_tokens = event["cachedInputTokens"]
            output_tokens = event["outputTokens"]
            usage = by_model.setdefault(model, {
                "model": model,
                "inputTokens": 0,
                "cachedInputTokens": 0,
                "outputTokens": 0,
                "reasoningTokens": 0,
                "completionCount": 0,
                "longContextInputTokens": 0,
                "longContextCachedInputTokens": 0,
                "longContextOutputTokens": 0,
            })
            usage["longContextInputTokens"] += input_tokens
            usage["longContextCachedInputTokens"] += cached_tokens
            usage["longContextOutputTokens"] += output_tokens

        for line in usage_lines():
            session_event = parse_token_count_usage(line)
            if session_event is not None:
                session_id = session_event.get("sessionId")
                if session_id:
                    existing = session_totals.get(session_id)
                    score = session_event["inputTokens"] + session_event["outputTokens"] + session_event["reasoningTokens"]
                    existing_score = -1 if existing is None else existing["inputTokens"] + existing["outputTokens"] + existing["reasoningTokens"]
                    if score >= existing_score:
                        session_totals[session_id] = session_event
                continue

            turn_event = parse_turn_aggregate_usage(line)
            if turn_event is not None:
                existing = turn_aggregates.get(turn_event["turnId"])
                score = turn_event["inputTokens"] + turn_event["outputTokens"] + turn_event["reasoningTokens"]
                existing_score = -1 if existing is None else existing["inputTokens"] + existing["outputTokens"] + existing["reasoningTokens"]
                if score >= existing_score:
                    turn_aggregates[turn_event["turnId"]] = turn_event
                continue

            input_tokens = int_field(line, "input_token_count")
            cached_tokens = int_field(line, "cached_token_count")
            output_tokens = int_field(line, "output_token_count")
            reasoning_tokens = int_field(line, "reasoning_token_count") or 0
            model = field(line, "slug") or field(line, "model")
            if input_tokens is None or cached_tokens is None or output_tokens is None:
                parsed_json = parse_json_object_usage(line)
                if parsed_json is not None:
                    input_tokens, cached_tokens, output_tokens, reasoning_tokens, model = parsed_json
                else:
                    input_tokens = json_int_field(line, "input_tokens")
                    cached_tokens = json_int_field(line, "cached_tokens") or json_int_field(line, "cached_input_tokens") or 0
                    output_tokens = json_int_field(line, "output_tokens")
                    reasoning_tokens = json_int_field(line, "reasoning_tokens") or 0
                    model = json_string_field(line, "model") or model
            if input_tokens is None or output_tokens is None:
                continue
            timestamp = field(line, "codexswitch_ts") or field(line, "event.timestamp") or "unknown-timestamp"
            model = normalize_model(model)
            cached_tokens = min(cached_tokens or 0, input_tokens)
            turn_id = field(line, "turn.id")
            key = (timestamp, turn_id, model, input_tokens, cached_tokens, output_tokens, reasoning_tokens)
            if key in response_seen:
                continue
            response_seen.add(key)
            response_events.append({
                "kind": "response",
                "sessionId": field(line, "codexswitch_session") or field(line, "thread_id") or field(line, "thread.id"),
                "turnId": turn_id,
                "timestamp": timestamp,
                "model": model,
                "inputTokens": input_tokens,
                "cachedInputTokens": cached_tokens,
                "outputTokens": output_tokens,
                "reasoningTokens": reasoning_tokens,
            })

        aggregated_session_ids = set(session_totals.keys())
        aggregated_turn_ids = set(turn_aggregates.keys())
        for event in sorted(session_totals.values(), key=lambda item: item["timestamp"]):
            add_usage(event)
        for event in sorted(turn_aggregates.values(), key=lambda item: item["timestamp"]):
            if event.get("sessionId") in aggregated_session_ids:
                continue
            add_usage(event)
        for event in sorted(response_events, key=lambda item: item["timestamp"]):
            if event.get("kind") != "response":
                continue
            if not (event["inputTokens"] > LONG_CONTEXT_THRESHOLD and event["model"].lower() in ("gpt-5.5", "gpt-5.4")):
                continue
            if event.get("sessionId") in aggregated_session_ids or event.get("turnId") in aggregated_turn_ids:
                add_long_context_pricing(event)
        for event in sorted(response_events, key=lambda item: item["timestamp"]):
            if event.get("sessionId") in aggregated_session_ids:
                continue
            if event.get("turnId") in aggregated_turn_ids:
                continue
            add_usage(event)

        report = {
            "source": "linuxDevbox",
            "generatedAt": time.time() - REFERENCE,
            "windowDays": DAYS,
            "accountTokenHashPrefixes": token_hashes(load_accounts()),
            "models": sorted(by_model.values(), key=lambda item: item["model"]),
        }
        if first_event_at is not None:
            report["firstEventAt"] = first_event_at - REFERENCE
        print(json.dumps(report))
        PY
        """
    }
}
