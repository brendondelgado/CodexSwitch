import Foundation

enum CodexInstallChannel: Equatable {
    case homebrewCask
    case npmGlobal
    case unknown
}

struct CodexInstall: Equatable {
    let executablePath: String
    let resolvedExecutablePath: String
    let patchTargetPath: String
    let channel: CodexInstallChannel
}

enum CodexInstallLocator {
    static let defaultExecutablePath = "/opt/homebrew/bin/codex"
    static let defaultNpmVendorBinaryPath = "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex"

    static func install(
        whichCodexPath: String,
        resolvedExecutablePath: String,
        npmVendorBinaryPath: String = defaultNpmVendorBinaryPath
    ) -> CodexInstall {
        if resolvedExecutablePath.contains("/Caskroom/codex/") {
            return CodexInstall(
                executablePath: whichCodexPath,
                resolvedExecutablePath: resolvedExecutablePath,
                patchTargetPath: resolvedExecutablePath,
                channel: .homebrewCask
            )
        }

        if resolvedExecutablePath.hasSuffix(".js")
            || resolvedExecutablePath.contains("/lib/node_modules/@openai/codex/")
        {
            return CodexInstall(
                executablePath: whichCodexPath,
                resolvedExecutablePath: resolvedExecutablePath,
                patchTargetPath: npmVendorBinaryPath,
                channel: .npmGlobal
            )
        }

        return CodexInstall(
            executablePath: whichCodexPath,
            resolvedExecutablePath: resolvedExecutablePath,
            patchTargetPath: resolvedExecutablePath,
            channel: .unknown
        )
    }

    static func locate() -> CodexInstall? {
        let executablePath = locateExecutablePath() ?? defaultExecutablePath
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return nil
        }

        let resolvedPath = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath()
            .path

        return install(
            whichCodexPath: executablePath,
            resolvedExecutablePath: resolvedPath
        )
    }

    static func currentVersion() -> String {
        let executablePath = locateExecutablePath() ?? defaultExecutablePath
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return "?"
        }

        guard let output = ProcessRunner.run(
            executablePath: executablePath,
            arguments: ["--version"],
            timeout: 2
        ) else {
            return "?"
        }
        guard !output.timedOut else { return "?" }
        let version = output.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "codex-cli ", with: "")
        return version.isEmpty ? "?" : version
    }

    private static func locateExecutablePath() -> String? {
        guard let output = ProcessRunner.run(
            executablePath: "/usr/bin/which",
            arguments: ["codex"],
            timeout: 1
        ) else {
            return nil
        }
        guard !output.timedOut else { return nil }
        let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
