import AppKit
import Foundation

struct CodexDesktopAppInstall: Equatable, Sendable {
    let appPath: String
    let asarPath: String
    let bundleVersion: String
    let shortVersion: String

    var versionLabel: String {
        "\(shortVersion) (\(bundleVersion))"
    }
}

enum CodexDesktopAppSignatureStatus: Equatable, Sendable {
    case officialOpenAI
    case adHoc
    case nonOpenAISigned
    case unreadable
}

enum CodexDesktopAppLocator {
    static let appBundleIdentifier = "com.openai.codex"
    static let defaultAppPaths = [
        "/Applications/ChatGPT.app",
        "/Applications/Codex.app",
    ]

    private static let requiredPatchMarkers = [
        "_invalidateAccountQueries",
        "CODEXSWITCH_AUTH_CACHE_INVALIDATION_V2",
        "CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH_V2",
        "CODEXSWITCH_RECENT_THREADS_STATE_DB_V1",
        "CODEXSWITCH_MODEL_LABEL_FALLBACK",
        "CODEXSWITCH_MODEL_AVAILABILITY_FALLBACK",
        "CODEXSWITCH_SELECTED_MODEL_LABEL_FALLBACK",
        "CODEXSWITCH_GPT56_MAX_EFFORT_FALLBACK",
        "CODEXSWITCH_REMOTE_MODEL_REFRESH_PATCH",
        "CODEXSWITCH_NATIVE_UPDATER_DISABLED_V1",
        "_bundledFastModels",
    ]

    private static let legacyPatchMarkers = [
        "_codexSwitchEnsureDesktopAuthSync",
        "codexSwitchLoginWithChatGptAuthTokens",
        "codexSwitchReadHostFile",
    ]

    static func locate(candidateAppPaths: [String] = defaultAppPaths) -> CodexDesktopAppInstall? {
        candidateAppPaths.lazy.compactMap { locate(appPath: $0) }.first
    }

    static func locate(appPath: String) -> CodexDesktopAppInstall? {
        let appURL = URL(fileURLWithPath: appPath)
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let asarURL = appURL.appendingPathComponent("Contents/Resources/app.asar")

        guard FileManager.default.fileExists(atPath: asarURL.path),
              let infoData = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: infoData,
                  options: [],
                  format: nil
              ) as? [String: Any] else {
            return nil
        }

        return CodexDesktopAppInstall(
            appPath: appPath,
            asarPath: asarURL.path,
            bundleVersion: plist["CFBundleVersion"] as? String ?? "?",
            shortVersion: plist["CFBundleShortVersionString"] as? String ?? "?"
        )
    }

    static func patchMarkerPresent(install: CodexDesktopAppInstall) -> Bool {
        guard let data = mappedAsarData(for: install) else { return false }
        return requiredPatchMarkers.allSatisfy { marker in
            data.range(of: Data(marker.utf8)) != nil
        } && !containsLegacyPatchMarker(in: data)
    }

    static func legacyPatchMarkerPresent(install: CodexDesktopAppInstall) -> Bool {
        guard let data = mappedAsarData(for: install) else { return false }
        return containsLegacyPatchMarker(in: data)
    }

    static func bundleIsValid(appPath: String? = nil) -> Bool {
        guard let appPath = appPath ?? locate()?.appPath else { return false }
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", appPath],
            timeout: 15
        )
        return !result.timedOut && result.terminationStatus == 0
    }

    static func signatureStatus(appPath: String? = nil) -> CodexDesktopAppSignatureStatus {
        guard let appPath = appPath ?? locate()?.appPath else { return .unreadable }
        let output = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dvvv", appPath],
            timeout: 5
        )
        guard !output.timedOut, output.terminationStatus == 0 else {
            return .unreadable
        }
        return signatureStatus(from: output.stdoutString + "\n" + output.stderrString)
    }

    static func signatureStatus(from output: String) -> CodexDesktopAppSignatureStatus {
        if output.contains("Signature=adhoc") {
            return .adHoc
        }
        if output.contains("TeamIdentifier=2DC432GLL2") {
            return .officialOpenAI
        }
        if output.contains("TeamIdentifier=") {
            return .nonOpenAISigned
        }
        return .unreadable
    }

    static func isCodexApplication(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == appBundleIdentifier
    }

    private static func mappedAsarData(for install: CodexDesktopAppInstall) -> Data? {
        try? Data(
            contentsOf: URL(fileURLWithPath: install.asarPath),
            options: [.mappedIfSafe]
        )
    }

    private static func containsLegacyPatchMarker(in data: Data) -> Bool {
        legacyPatchMarkers.contains { marker in
            data.range(of: Data(marker.utf8)) != nil
        }
    }
}
