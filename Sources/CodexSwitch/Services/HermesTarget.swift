import CryptoKit
import Darwin
import Foundation

struct HermesStatus: Sendable, Equatable {
    let hermesHomeExists: Bool
    let authExists: Bool
    let envExists: Bool
    let configExists: Bool
    let provider: String?
    let model: String?
    let tokenHashPrefix: String?
    let activeProvider: String?
    let gatewayStatus: String?
    let tuiRunning: Bool

    var summary: String {
        guard hermesHomeExists else { return "Hermes home not found" }
        guard authExists else { return "Hermes OpenAI Codex auth not installed" }
        if activeProvider != "openai-codex" {
            return "Hermes auth exists but OpenAI Codex is not active"
        }
        return "Hermes OpenAI Codex auth ready"
    }
}

struct HermesApplyResult: Sendable, Equatable {
    let authPath: String
    let tokenHashPrefix: String
    let authBackupPath: String?
    let envBackupPath: String?
    let gatewayRestarted: Bool
    let tuiRunning: Bool

    var restartHint: String? {
        tuiRunning ? "Hermes TUI is running; restart/resume it to pick up the updated token." : nil
    }
}

enum HermesTargetError: LocalizedError {
    case missingTokenMaterial
    case invalidAuthStore
    case gatewayRestartFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTokenMaterial:
            return "selected account is missing OAuth token material"
        case .invalidAuthStore:
            return "Hermes auth store is not a JSON object"
        case .gatewayRestartFailed(let message):
            return "Hermes gateway restart failed: \(message)"
        }
    }
}

enum HermesTarget {
    static let providerIdentifier = "openai-codex"
    static let defaultModel = "gpt-5.5"
    static let defaultBaseURL = "https://chatgpt.com/backend-api/codex"

    static func defaultHermesHome() -> URL {
        URL(fileURLWithPath: NSString(string: "~/.hermes").expandingTildeInPath, isDirectory: true)
    }

    static func status(
        hermesHome: URL = defaultHermesHome(),
        includeGateway: Bool = false
    ) -> HermesStatus {
        let fileManager = FileManager.default
        let authURL = hermesHome.appendingPathComponent("auth.json")
        let envURL = hermesHome.appendingPathComponent(".env")
        let configURL = hermesHome.appendingPathComponent("config.yaml")

        let auth = (try? readJSONObject(at: authURL)) ?? [:]
        let openAICodex = ((auth["providers"] as? [String: Any])?[providerIdentifier] as? [String: Any]) ?? [:]
        let tokens = openAICodex["tokens"] as? [String: Any]
        let accessToken = tokens?["access_token"] as? String
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let gateway = includeGateway ? gatewayStatus() : nil

        return HermesStatus(
            hermesHomeExists: fileManager.fileExists(atPath: hermesHome.path),
            authExists: fileManager.fileExists(atPath: authURL.path),
            envExists: fileManager.fileExists(atPath: envURL.path),
            configExists: fileManager.fileExists(atPath: configURL.path),
            provider: yamlScalar(named: "provider", underTopLevelKey: "model", in: config),
            model: yamlScalar(named: "default", underTopLevelKey: "model", in: config),
            tokenHashPrefix: accessToken.map(tokenHashPrefix),
            activeProvider: auth["active_provider"] as? String,
            gatewayStatus: gateway,
            tuiRunning: isHermesTUIRunning()
        )
    }

    @discardableResult
    static func applyLocal(
        account: CodexAccount,
        hermesHome: URL = defaultHermesHome(),
        restartGateway: Bool = false,
        configureModel: Bool = true
    ) throws -> HermesApplyResult {
        guard !account.accessToken.isEmpty, !account.refreshToken.isEmpty else {
            throw HermesTargetError.missingTokenMaterial
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: hermesHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hermesHome.path)

        let envBackup = try hardenEnvIfPresent(hermesHome: hermesHome)
        let authURL = hermesHome.appendingPathComponent("auth.json")
        let authBackup = try backupIfExists(authURL)
        try writeHermesAuth(account: account, to: authURL)

        if configureModel {
            try configureHermesModel(hermesHome: hermesHome)
        }

        var gatewayRestarted = false
        if restartGateway {
            try restartGatewayProcess()
            gatewayRestarted = true
        }

        return HermesApplyResult(
            authPath: authURL.path,
            tokenHashPrefix: tokenHashPrefix(account.accessToken),
            authBackupPath: authBackup?.path,
            envBackupPath: envBackup?.path,
            gatewayRestarted: gatewayRestarted,
            tuiRunning: isHermesTUIRunning()
        )
    }

    static func mergeHermesAuth(account: CodexAccount, existing: [String: Any] = [:]) -> [String: Any] {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var root = existing
        root["version"] = root["version"] ?? 1
        root["updated_at"] = timestamp
        root["active_provider"] = providerIdentifier

        var providers = root["providers"] as? [String: Any] ?? [:]
        var providerState = providers[providerIdentifier] as? [String: Any] ?? [:]
        var tokens = providerState["tokens"] as? [String: Any] ?? [:]
        tokens["id_token"] = account.idToken
        tokens["access_token"] = account.accessToken
        tokens["refresh_token"] = account.refreshToken
        tokens["account_id"] = account.accountId
        providerState["tokens"] = tokens
        providerState["last_refresh"] = timestamp
        providerState["auth_mode"] = "chatgpt"
        providerState["label"] = account.email
        providers[providerIdentifier] = providerState
        root["providers"] = providers
        return root
    }

    static func updateModelConfigText(_ text: String, model: String = defaultModel) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let modelIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "model:" }) else {
            var output = text
            if !output.isEmpty, !output.hasSuffix("\n") {
                output += "\n"
            }
            output += """
            model:
              default: "\(model)"
              provider: "\(providerIdentifier)"
              base_url: "\(defaultBaseURL)"
            """
            return output + "\n"
        }

        let endIndex = lines[(modelIndex + 1)...].firstIndex { line in
            !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t")
        } ?? lines.endIndex
        var block = Array(lines[modelIndex..<endIndex])
        upsertYamlScalar("default", value: model, in: &block)
        upsertYamlScalar("provider", value: providerIdentifier, in: &block)
        upsertYamlScalar("base_url", value: defaultBaseURL, in: &block)
        lines.replaceSubrange(modelIndex..<endIndex, with: block)
        return lines.joined(separator: "\n") + (text.hasSuffix("\n") ? "\n" : "")
    }

    static func tokenHashPrefix(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    private static func writeHermesAuth(account: CodexAccount, to authURL: URL) throws {
        let existing = try readJSONObjectIfPresent(at: authURL)
        let merged = mergeHermesAuth(account: account, existing: existing)
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        let tmpURL = authURL.deletingLastPathComponent().appendingPathComponent(".auth.json.codexswitch-\(UUID().uuidString).tmp")
        try data.write(to: tmpURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
        if FileManager.default.fileExists(atPath: authURL.path) {
            try FileManager.default.removeItem(at: authURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: authURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    }

    private static func readJSONObjectIfPresent(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try readJSONObject(at: url)
    }

    private static func readJSONObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HermesTargetError.invalidAuthStore
        }
        return object
    }

    private static func hardenEnvIfPresent(hermesHome: URL) throws -> URL? {
        let envURL = hermesHome.appendingPathComponent(".env")
        guard FileManager.default.fileExists(atPath: envURL.path) else { return nil }
        let backup = try backupIfExists(envURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envURL.path)
        return backup
    }

    private static func backupIfExists(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).codexswitch-backup-\(formatter.string(from: Date()))")
        try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.copyItem(at: url, to: backupURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        return backupURL
    }

    private static func configureHermesModel(hermesHome: URL) throws {
        let configURL = hermesHome.appendingPathComponent("config.yaml")
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated = updateModelConfigText(existing)
        try updated.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private static func upsertYamlScalar(_ key: String, value: String, in block: inout [String]) {
        let replacement = "  \(key): \"\(value)\""
        if let index = block.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }) {
            block[index] = replacement
        } else {
            block.append(replacement)
        }
    }

    private static func yamlScalar(named key: String, underTopLevelKey parent: String, in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let parentIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "\(parent):" }) else {
            return nil
        }
        for line in lines[(parentIndex + 1)...] {
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                return nil
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            return trimmed
                .dropFirst(key.count + 1)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private static func gatewayStatus() -> String? {
        guard let hermes = hermesExecutablePath() else { return nil }
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: hermes),
            arguments: ["gateway", "status"],
            timeout: 8
        )
        let output = (result.stdoutString + result.stderrString)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.timedOut { return "timeout" }
        return output.isEmpty ? "exit \(result.terminationStatus)" : output
    }

    private static func restartGatewayProcess() throws {
        guard let hermes = hermesExecutablePath() else {
            throw HermesTargetError.gatewayRestartFailed("hermes executable not found")
        }
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: hermes),
            arguments: ["gateway", "restart"],
            timeout: 30
        )
        guard result.terminationStatus == 0, !result.timedOut else {
            let message = (result.stderrString + result.stdoutString)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HermesTargetError.gatewayRestartFailed(message.isEmpty ? "exit \(result.terminationStatus)" : message)
        }
    }

    private static func hermesExecutablePath() -> String? {
        let candidates = [
            NSString(string: "~/.local/bin/hermes").expandingTildeInPath,
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
            "/usr/bin/hermes",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func isHermesTUIRunning() -> Bool {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,command="],
            timeout: 2
        )
        guard result.terminationStatus == 0 else { return false }
        return result.stdoutString
            .split(separator: "\n")
            .map(String.init)
            .contains { line in
                let lower = line.lowercased()
                return lower.contains("hermes")
                    && (lower.contains("--tui") || lower.contains(" hermes tui"))
                    && !lower.contains("codexswitch-cli")
                    && !lower.contains("pgrep")
            }
    }
}
