import Foundation

struct CodexPatchedInstallState: Codable, Equatable {
    let version: String
    let patchTargetPath: String
}

enum CodexPatchStateStore {
    private static let statePath = NSString("~/.codexswitch/patched-install.json").expandingTildeInPath

    static func load() -> CodexPatchedInstallState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)) else {
            return nil
        }

        return try? JSONDecoder().decode(CodexPatchedInstallState.self, from: data)
    }

    static func save(_ state: CodexPatchedInstallState) throws {
        let parent = URL(fileURLWithPath: statePath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    static func matchesCurrentInstall(
        currentVersion: String,
        currentInstall: CodexInstall
    ) -> Bool {
        guard let savedState = load() else { return false }
        return savedState.version == currentVersion
            && savedState.patchTargetPath == currentInstall.patchTargetPath
    }
}

enum CodexSighupMarkers {
    static let markerDirectoryPath = NSString("~/.codexswitch").expandingTildeInPath
    private static let verificationMarkerNames = [
        "sighup-verified",
        "sighup-verified-tui",
        "sighup-verified-exec",
    ]

    static func hasVerifiedMarker(
        markerDirectory: String = markerDirectoryPath,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        verificationMarkerNames
            .map { "\(markerDirectory)/\($0)" }
            .contains(where: fileExists)
    }
}

enum CodexPatchRepairDecider {
    static func stockBackupPath(
        currentInstall: CodexInstall,
        currentVersion: String
    ) -> String {
        "\(currentInstall.patchTargetPath).stock-v\(currentVersion)"
    }

    static func canRecoverPatchedState(
        verifiedMarkerPresent: Bool,
        currentInstall: CodexInstall,
        currentVersion: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard verifiedMarkerPresent else { return false }
        guard currentVersion != "?" else { return false }
        return fileExists(stockBackupPath(
            currentInstall: currentInstall,
            currentVersion: currentVersion
        ))
    }

    static func needsRepair(
        forkEnabled: Bool,
        currentInstall: CodexInstall,
        currentVersion: String,
        savedState: CodexPatchedInstallState?
    ) -> Bool {
        guard forkEnabled else { return false }
        guard currentVersion != "?" else { return false }
        guard let savedState else { return true }

        return savedState.version != currentVersion
            || savedState.patchTargetPath != currentInstall.patchTargetPath
    }
}
