import Foundation

enum CodexConfigRepair {
    struct RepairResult: Equatable {
        var text: String
        var changed: Bool
    }

    struct BundledPluginDiscoveryRepairResult: Equatable {
        var attempted: Bool
        var changed: Bool
        var success: Bool
        var message: String
    }

    private static let defaultConfigPath =
        NSString("~/.codex/config.toml").expandingTildeInPath
    private static var bundledMarketplaceAppPath: String {
        let appPath = CodexDesktopAppLocator.locate()?.appPath
            ?? CodexDesktopAppLocator.defaultAppPaths[0]
        return "\(appPath)/Contents/Resources/plugins/openai-bundled"
    }
    private static let defaultCodexHome =
        NSString("~/.codex").expandingTildeInPath
    private static let bundledMarketplaceCachePathPattern =
        #"(?:~|/Users/[^"'\s]+|/var/[^"'\s]+|/private/var/[^"'\s]+)?/\.codex/\.tmp/bundled-marketplaces/openai-bundled"#

    static func repairDefaultConfigIfNeeded(
        configPath: String = defaultConfigPath,
        removeStaleCopies: Bool = true,
        appMarketplacePath: String = bundledMarketplaceAppPath
    ) {
        if removeStaleCopies {
            removeStaleBundledMarketplaceCopies()
            let discoveryResult = ensureBundledPluginDiscoveryIfNeeded(
                appMarketplacePath: appMarketplacePath
            )
            if discoveryResult.attempted, !discoveryResult.success {
                SwapLog.append(.debug("CODEX_BUNDLED_PLUGIN_DISCOVERY_REPAIR_FAILED message=\(discoveryResult.message)"))
            }
        }

        let url = URL(fileURLWithPath: configPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let repaired = repairedConfigText(
                text,
                appMarketplacePath: appMarketplacePath
            )
            guard repaired.changed else { return }
            try repaired.text.write(to: url, atomically: true, encoding: .utf8)
            SwapLog.append(.debug("CODEX_CONFIG_REPAIRED path=\(url.path) features=apps,plugins chronicle=false"))
        } catch {
            SwapLog.append(.debug("CODEX_CONFIG_REPAIR_FAILED path=\(url.path) error=\(error.localizedDescription)"))
        }
    }

    static func repairedConfigText(
        _ text: String,
        appMarketplacePath: String = bundledMarketplaceAppPath
    ) -> RepairResult {
        guard referencesBundledPlugins(text) else {
            return RepairResult(text: text, changed: false)
        }

        var result = ensureBundledMarketplaceAppPath(
            in: text,
            appMarketplacePath: appMarketplacePath
        )
        let notifyResult = removeStaleBundledComputerUseNotify(from: result.text)
        result.text = notifyResult.text
        result.changed = result.changed || notifyResult.changed
        let mcpResult = removeStaleBundledComputerUseMcpServer(from: result.text)
        result.text = mcpResult.text
        result.changed = result.changed || mcpResult.changed
        let appsResult = ensureBooleanFeature("apps", enabledIn: result.text)
        result.text = appsResult.text
        result.changed = result.changed || appsResult.changed
        let pluginResult = ensureBooleanFeature("plugins", enabledIn: result.text)
        result.text = pluginResult.text
        result.changed = result.changed || pluginResult.changed
        let chronicleResult = ensureBooleanFeature("chronicle", enabled: false, in: result.text)
        result.text = chronicleResult.text
        result.changed = result.changed || chronicleResult.changed
        return result
    }

    private static func referencesBundledPlugins(_ text: String) -> Bool {
        text.contains("[marketplaces.openai-bundled]")
            || text.contains("openai-bundled")
            && (text.contains("browser-use") || text.contains("computer-use"))
    }

    static func ensureBundledPluginDiscoveryIfNeeded(
        appMarketplacePath: String = bundledMarketplaceAppPath,
        codexHome: String = defaultCodexHome
    ) -> BundledPluginDiscoveryRepairResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: appMarketplacePath) else {
            return BundledPluginDiscoveryRepairResult(
                attempted: false,
                changed: false,
                success: false,
                message: "bundled OpenAI marketplace not found at \(appMarketplacePath)"
            )
        }

        var changed = false
        do {
            let bundledRoot = URL(fileURLWithPath: codexHome).appending(path: "openai-bundled")
            let bundledLink = bundledRoot.appending(path: "current")
            let marketplaceDir = URL(fileURLWithPath: codexHome).appending(path: ".agents/plugins")
            let marketplacePath = marketplaceDir.appending(path: "marketplace.json")
            let cacheRoot = URL(fileURLWithPath: codexHome).appending(path: "plugins/cache/openai-bundled")

            try fileManager.createDirectory(at: bundledRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: marketplaceDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

            if try ensureSymlink(at: bundledLink, destination: appMarketplacePath) {
                changed = true
            }

            let marketplaceText = bundledMarketplaceManifestText()
            let existingMarketplaceText = try? String(contentsOf: marketplacePath, encoding: .utf8)
            if existingMarketplaceText != marketplaceText {
                try marketplaceText.write(to: marketplacePath, atomically: true, encoding: .utf8)
                changed = true
            }

            for pluginName in ["browser-use", "computer-use"] {
                let source = URL(fileURLWithPath: appMarketplacePath).appending(path: "plugins/\(pluginName)")
                let base = cacheRoot.appending(path: pluginName)
                let target = base.appending(path: "local")
                if try repairBundledPluginCacheIfNeeded(pluginName: pluginName, source: source, base: base, target: target) {
                    changed = true
                }
            }

            if changed {
                SwapLog.append(.debug("CODEX_BUNDLED_PLUGIN_DISCOVERY_REPAIRED marketplace=\(marketplacePath.path) cache=\(cacheRoot.path)"))
            }
            return BundledPluginDiscoveryRepairResult(
                attempted: true,
                changed: changed,
                success: true,
                message: changed ? "bundled plugin discovery repaired" : "bundled plugin discovery already current"
            )
        } catch {
            return BundledPluginDiscoveryRepairResult(
                attempted: true,
                changed: changed,
                success: false,
                message: error.localizedDescription
            )
        }
    }

    private static func removeStaleBundledMarketplaceCopies() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let stalePaths = [
            "\(home)/.codex/.tmp/bundled-marketplaces/openai-bundled",
        ]

        for path in stalePaths where FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
                SwapLog.append(.debug("CODEX_STALE_BUNDLED_PLUGIN_COPY_REMOVED path=\(path)"))
            } catch {
                SwapLog.append(.debug("CODEX_STALE_BUNDLED_PLUGIN_COPY_REMOVE_FAILED path=\(path) error=\(error.localizedDescription)"))
            }
        }
    }

    private static func bundledMarketplaceManifestText() -> String {
        """
        {
          "name": "openai-bundled",
          "interface": { "displayName": "OpenAI Bundled" },
          "plugins": [
            {
              "name": "browser-use",
              "source": { "source": "local", "path": "./openai-bundled/current/plugins/browser-use" },
              "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" },
              "category": "Engineering"
            },
            {
              "name": "computer-use",
              "source": { "source": "local", "path": "./openai-bundled/current/plugins/computer-use" },
              "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" },
              "category": "Productivity"
            },
            {
              "name": "latex-tectonic",
              "source": { "source": "local", "path": "./openai-bundled/current/plugins/latex-tectonic" },
              "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" },
              "category": "Engineering"
            }
          ]
        }
        """
    }

    private static func ensureSymlink(at link: URL, destination: String) throws -> Bool {
        let fileManager = FileManager.default
        if let existingDestination = try? fileManager.destinationOfSymbolicLink(atPath: link.path),
           existingDestination == destination {
            return false
        }
        if fileManager.fileExists(atPath: link.path) || isDanglingSymlink(link.path) {
            try fileManager.removeItem(at: link)
        }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: destination))
        return true
    }

    private static func isDanglingSymlink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private static func repairBundledPluginCacheIfNeeded(
        pluginName: String,
        source: URL,
        base: URL,
        target: URL
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw NSError(
                domain: "CodexConfigRepair",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "bundled plugin source missing: \(source.path)"]
            )
        }

        let sourceVersion = pluginManifestVersion(at: source)
        let targetVersion = pluginManifestVersion(at: target)
        let currentVersions = cacheVersionDirectories(at: base)
        let nestedComputerUseApp = target.appending(path: "Codex Computer Use.app")
        let expectedComputerUseAppPath = source.appending(path: "Codex Computer Use.app").path
        let computerUseAppIsLinked = pluginName != "computer-use"
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: nestedComputerUseApp.path)) == expectedComputerUseAppPath
        let cacheIsCurrent = currentVersions == ["local"]
            && FileManager.default.fileExists(atPath: target.appending(path: ".codex-plugin/plugin.json").path)
            && sourceVersion == targetVersion
            && computerUseAppIsLinked
        guard !cacheIsCurrent else { return false }

        if FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.removeItem(at: base)
        }
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)

        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: [source.path, target.path],
            timeout: pluginName == "computer-use" ? 20 : 10
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            throw NSError(
                domain: "CodexConfigRepair",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "failed to copy \(pluginName) into Codex plugin cache: \(result.stderrString)"]
            )
        }
        if pluginName == "computer-use" {
            if FileManager.default.fileExists(atPath: nestedComputerUseApp.path) || isDanglingSymlink(nestedComputerUseApp.path) {
                try FileManager.default.removeItem(at: nestedComputerUseApp)
            }
            try FileManager.default.createSymbolicLink(
                at: nestedComputerUseApp,
                withDestinationURL: URL(fileURLWithPath: expectedComputerUseAppPath)
            )
        }
        return true
    }

    private static func cacheVersionDirectories(at base: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true ? url.lastPathComponent : nil
        }.sorted()
    }

    private static func pluginManifestVersion(at pluginRoot: URL) -> String? {
        let manifest = pluginRoot.appending(path: ".codex-plugin/plugin.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String else {
            return nil
        }
        return version
    }

    private static func ensureBundledMarketplaceAppPath(
        in text: String,
        appMarketplacePath: String
    ) -> RepairResult {
        let repaired = text.replacingOccurrences(
            of: bundledMarketplaceCachePathPattern,
            with: appMarketplacePath,
            options: .regularExpression
        )
        return RepairResult(text: repaired, changed: repaired != text)
    }

    private static func removeStaleBundledComputerUseNotify(from text: String) -> RepairResult {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hadTrailingNewline = text.hasSuffix("\n")
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("notify"), trimmed.contains("SkyComputerUseClient") else {
                return true
            }
            return false
        }
        return RepairResult(
            text: join(filtered, trailingNewline: hadTrailingNewline),
            changed: filtered != lines
        )
    }

    private static func removeStaleBundledComputerUseMcpServer(from text: String) -> RepairResult {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hadTrailingNewline = text.hasSuffix("\n")
        guard let sectionIndex = lines.firstIndex(where: { isSection($0, named: "mcp_servers.computer-use") }) else {
            return RepairResult(text: text, changed: false)
        }
        let sectionEnd = nextSectionIndex(in: lines, after: sectionIndex)
        let sectionText = lines[sectionIndex..<sectionEnd].joined(separator: "\n")
        guard sectionText.contains("SkyComputerUseClient"),
              sectionText.contains("openai-bundled/plugins/computer-use") else {
            return RepairResult(text: text, changed: false)
        }

        lines.removeSubrange(sectionIndex..<sectionEnd)
        while sectionIndex < lines.count, lines[sectionIndex].isEmpty,
              sectionIndex > 0, lines[sectionIndex - 1].isEmpty {
            lines.remove(at: sectionIndex)
        }
        return RepairResult(text: join(lines, trailingNewline: hadTrailingNewline), changed: true)
    }

    private static func ensureBooleanFeature(_ name: String, enabledIn text: String) -> RepairResult {
        ensureBooleanFeature(name, enabled: true, in: text)
    }

    private static func ensureBooleanFeature(_ name: String, enabled: Bool, in text: String) -> RepairResult {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hadTrailingNewline = text.hasSuffix("\n")
        let value = enabled ? "true" : "false"

        guard let featuresIndex = lines.firstIndex(where: { isSection($0, named: "features") }) else {
            if !lines.isEmpty, lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("[features]")
            lines.append("\(name) = \(value)")
            return RepairResult(text: join(lines, trailingNewline: hadTrailingNewline), changed: true)
        }

        let sectionEnd = nextSectionIndex(in: lines, after: featuresIndex)
        if let existingIndex = featureLineIndex(name, in: lines, range: (featuresIndex + 1)..<sectionEnd) {
            let leadingWhitespace = lines[existingIndex].prefix { $0 == " " || $0 == "\t" }
            let replacement = "\(leadingWhitespace)\(name) = \(value)"
            guard lines[existingIndex] != replacement else {
                return RepairResult(text: text, changed: false)
            }
            lines[existingIndex] = replacement
            return RepairResult(text: join(lines, trailingNewline: hadTrailingNewline), changed: true)
        }

        let anchorName = name == "chronicle" ? "plugins" : "apps"
        let insertIndex = featureLineIndex(anchorName, in: lines, range: (featuresIndex + 1)..<sectionEnd)
            .map { $0 + 1 } ?? (featuresIndex + 1)
        lines.insert("\(name) = \(value)", at: insertIndex)
        return RepairResult(text: join(lines, trailingNewline: hadTrailingNewline), changed: true)
    }

    private static func featureLineIndex(
        _ name: String,
        in lines: [String],
        range: Range<Int>
    ) -> Int? {
        for index in range {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(name) else { continue }
            let suffix = trimmed.dropFirst(name.count)
            if suffix.first == "=" || suffix.first?.isWhitespace == true {
                return index
            }
        }
        return nil
    }

    private static func nextSectionIndex(in lines: [String], after index: Int) -> Int {
        for candidate in (index + 1)..<lines.count {
            let trimmed = lines[candidate].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                return candidate
            }
        }
        return lines.count
    }

    private static func isSection(_ line: String, named name: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "[\(name)]"
    }

    private static func join(_ lines: [String], trailingNewline: Bool) -> String {
        lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }
}
