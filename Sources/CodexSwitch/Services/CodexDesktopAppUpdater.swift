import AppKit
import Foundation

struct CodexDesktopAppRelease: Equatable, Sendable {
    let shortVersion: String
    let bundleVersion: String
    let downloadURL: URL

    var versionLabel: String {
        "\(shortVersion) (\(bundleVersion))"
    }
}

enum CodexDesktopAppcastParser {
    static func latestRelease(from data: Data) -> CodexDesktopAppRelease? {
        guard let xml = String(data: data, encoding: .utf8),
              let itemXML = firstTagBlock(named: "item", in: xml),
              let enclosureTag = firstTag(named: "enclosure", in: itemXML) else {
            return nil
        }

        let itemMetadata = parseSparkleMetadata(in: itemXML)
        let attributes = parseAttributes(in: enclosureTag)
        guard let urlString = attributes["url"],
              let shortVersion = itemMetadata.shortVersion ?? attributes["sparkle:shortVersionString"],
              let bundleVersion = itemMetadata.bundleVersion ?? attributes["sparkle:version"],
              let downloadURL = URL(string: urlString) else {
            return nil
        }

        return CodexDesktopAppRelease(
            shortVersion: shortVersion,
            bundleVersion: bundleVersion,
            downloadURL: downloadURL
        )
    }

    private static func firstTagBlock(named tagName: String, in xml: String) -> String? {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tagName))\\b[^>]*>[\\s\\S]*?</\(NSRegularExpression.escapedPattern(for: tagName))>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: xml,
                range: NSRange(xml.startIndex..., in: xml)
              ),
              let range = Range(match.range, in: xml) else {
            return nil
        }

        return String(xml[range])
    }

    private static func firstTag(named tagName: String, in xml: String) -> String? {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tagName))\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: xml,
                range: NSRange(xml.startIndex..., in: xml)
              ),
              let range = Range(match.range, in: xml) else {
            return nil
        }

        return String(xml[range])
    }

    private static func parseSparkleMetadata(in itemXML: String) -> (shortVersion: String?, bundleVersion: String?) {
        (
            firstText(in: itemXML, tagName: "sparkle:shortVersionString"),
            firstText(in: itemXML, tagName: "sparkle:version")
        )
    }

    private static func firstText(in xml: String, tagName: String) -> String? {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tagName))\\b[^>]*>([^<]+)</\(NSRegularExpression.escapedPattern(for: tagName))>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: xml,
                range: NSRange(xml.startIndex..., in: xml)
              ),
              match.numberOfRanges == 2,
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }

        return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseAttributes(in tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z0-9:_-]+)="([^"]*)""#) else {
            return [:]
        }

        var attributes: [String: String] = [:]
        let nsRange = NSRange(tag.startIndex..., in: tag)
        for match in regex.matches(in: tag, range: nsRange) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: tag),
                  let valueRange = Range(match.range(at: 2), in: tag) else {
                continue
            }
            attributes[String(tag[keyRange])] = String(tag[valueRange])
        }
        return attributes
    }
}

struct CodexDesktopAppUpdateResult: Sendable {
    let success: Bool
    let message: String
}

enum CodexDesktopAppUpdater {
    private static let appcastURL = URL(string: "https://persistent.oaistatic.com/codex-app-prod/appcast.xml")!
    private static let installedAppPath = "/Applications/Codex.app"

    static func latestRelease() async -> CodexDesktopAppRelease? {
        var request = URLRequest(url: appcastURL)
        request.timeoutInterval = 20
        request.setValue("CodexSwitch/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }

            return CodexDesktopAppcastParser.latestRelease(from: data)
        } catch {
            return nil
        }
    }

    static func installLatestStock(
        _ release: CodexDesktopAppRelease
    ) async -> CodexDesktopAppUpdateResult {
        do {
            try await stopInstalledAppIfNeeded()

            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexSwitch-DesktopUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            let zipPath = workDir.appendingPathComponent("Codex.app.zip")
            let extractedRoot = workDir.appendingPathComponent("extract", isDirectory: true)
            try FileManager.default.createDirectory(at: extractedRoot, withIntermediateDirectories: true)

            var request = URLRequest(url: release.downloadURL)
            request.timeoutInterval = 300
            request.setValue("CodexSwitch/1.0", forHTTPHeaderField: "User-Agent")
            let (downloadedFile, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return CodexDesktopAppUpdateResult(
                    success: false,
                    message: "Desktop download failed with HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                )
            }

            if FileManager.default.fileExists(atPath: zipPath.path) {
                try FileManager.default.removeItem(at: zipPath)
            }
            try FileManager.default.moveItem(at: downloadedFile, to: zipPath)

            try run(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", zipPath.path, extractedRoot.path]
            )

            guard let extractedApp = findCodexApp(in: extractedRoot) else {
                return CodexDesktopAppUpdateResult(
                    success: false,
                    message: "Downloaded latest Codex desktop build, but the app bundle was missing"
                )
            }

            if FileManager.default.fileExists(atPath: installedAppPath) {
                try FileManager.default.removeItem(atPath: installedAppPath)
            }

            try run(
                executable: "/usr/bin/ditto",
                arguments: [extractedApp.path, installedAppPath]
            )

            guard CodexDesktopAppLocator.bundleIsValid(appPath: installedAppPath),
                  CodexDesktopAppLocator.signatureStatus(appPath: installedAppPath) == .officialOpenAI else {
                return CodexDesktopAppUpdateResult(
                    success: false,
                    message: "Installed Codex.app \(release.versionLabel), but the signature was not the expected OpenAI stock signature"
                )
            }

            try run(
                executable: "/usr/bin/open",
                arguments: ["-a", installedAppPath]
            )

            return CodexDesktopAppUpdateResult(
                success: true,
                message: "Installed and relaunched stock Codex.app \(release.versionLabel)"
            )
        } catch {
            return CodexDesktopAppUpdateResult(
                success: false,
                message: "Desktop update failed: \(error.localizedDescription)"
            )
        }
    }

    private static func stopInstalledAppIfNeeded() async throws {
        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexDesktopAppLocator.appBundleIdentifier
        )
        for app in runningApps {
            _ = app.terminate()
        }

        for _ in 0..<50 {
            if runningApps.allSatisfy(\.isTerminated) {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        for app in runningApps where !app.isTerminated {
            _ = app.forceTerminate()
        }

        _ = try? run(
            executable: "/usr/bin/pkill",
            arguments: ["-f", "\(installedAppPath)/Contents/Resources/codex app-server"],
            allowFailure: true
        )
    }

    private static func findCodexApp(in root: URL) -> URL? {
        let candidates = [
            root.appendingPathComponent("Codex.app"),
            root.appendingPathComponent("Codex/Codex.app"),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            if url.lastPathComponent == "Codex.app" {
                return url
            }
        }
        return nil
    }

    @discardableResult
    private static func run(
        executable: String,
        arguments: [String],
        allowFailure: Bool = false
    ) throws -> String {
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = [
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? "",
        ]
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus != 0 && !allowFailure {
            throw NSError(
                domain: "CodexDesktopAppUpdater",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "Command failed" : output]
            )
        }

        return output
    }
}
