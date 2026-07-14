import Foundation
import Testing
@testable import CodexSwitch

@Suite("Codex config repair")
struct CodexConfigRepairTests {
    private let unifiedMarketplacePath =
        "/Applications/ChatGPT.app/Contents/Resources/plugins/openai-bundled"

    @Test("Bundled plugins enable both app and plugin feature gates")
    func bundledPluginsEnableRequiredFeatureGates() {
        let input = """
        model = "gpt-5.5"

        [features]
        apps = true
        plugins = false
        chronicle = true
        shell_snapshot = true

        [plugins."browser-use@openai-bundled"]
        enabled = true

        [plugins."computer-use@openai-bundled"]
        enabled = true
        """

        let result = CodexConfigRepair.repairedConfigText(
            input,
            appMarketplacePath: unifiedMarketplacePath
        )

        #expect(result.changed)
        #expect(result.text.contains("[features]\napps = true\nplugins = true\nchronicle = false\nshell_snapshot = true"))
    }

    @Test("Missing plugin feature gate is inserted into existing features section")
    func missingPluginFeatureGateIsInserted() {
        let input = """
        [features]
        apps = true
        codex_hooks = true

        [marketplaces.openai-bundled]
        source_type = "local"
        """

        let result = CodexConfigRepair.repairedConfigText(input)

        #expect(result.changed)
        #expect(result.text.contains("[features]\napps = true\nplugins = true\nchronicle = false\ncodex_hooks = true"))
    }

    @Test("Stale bundled Computer Use notify and MCP overrides are removed")
    func staleBundledComputerUseNotifyAndMcpOverridesAreRemoved() {
        let input = """
        notify = [ "/Users/brendondelgado/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient", "turn-ended" ]

        [features]
        apps = true
        plugins = true
        chronicle = true

        [mcp_servers.computer-use]
        command = "/Users/brendondelgado/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"

        [marketplaces.openai-bundled]
        source_type = "local"
        source = "/Users/brendondelgado/.codex/.tmp/bundled-marketplaces/openai-bundled"
        """

        let result = CodexConfigRepair.repairedConfigText(input)

        #expect(result.changed)
        #expect(!result.text.contains("notify ="))
        #expect(!result.text.contains("[mcp_servers.computer-use]"))
        #expect(!result.text.contains("SkyComputerUseClient"))
        #expect(result.text.contains("chronicle = false"))
        #expect(result.text.contains("source = \"\(unifiedMarketplacePath)\""))
    }

    @Test("Unrelated notify commands and MCP servers are preserved")
    func unrelatedNotifyAndMcpServersArePreserved() {
        let input = """
        notify = [ "/usr/bin/osascript", "turn-ended" ]

        [features]
        apps = true
        plugins = true
        chronicle = true

        [mcp_servers.docs]
        command = "docs-mcp"

        [marketplaces.openai-bundled]
        source_type = "local"
        source = "/Users/brendondelgado/.codex/.tmp/bundled-marketplaces/openai-bundled"
        """

        let result = CodexConfigRepair.repairedConfigText(
            input,
            appMarketplacePath: unifiedMarketplacePath
        )

        #expect(result.changed)
        #expect(result.text.contains("notify = [ \"/usr/bin/osascript\", \"turn-ended\" ]"))
        #expect(result.text.contains("[mcp_servers.docs]"))
        #expect(result.text.contains("command = \"docs-mcp\""))
        #expect(result.text.contains("chronicle = false"))
        #expect(result.text.contains("source = \"\(unifiedMarketplacePath)\""))
    }

    @Test("Config without bundled plugins is left untouched")
    func configWithoutBundledPluginsIsUnchanged() {
        let input = """
        [features]
        apps = false
        plugins = false
        """

        let result = CodexConfigRepair.repairedConfigText(input)

        #expect(!result.changed)
        #expect(result.text == input)
    }

    @Test("Default repair can skip destructive cache cleanup")
    func defaultRepairCanSkipDestructiveCacheCleanup() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "codex-config-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let config = tempDir.appending(path: "config.toml")
        try """
        [features]
        apps = true
        plugins = true

        [marketplaces.openai-bundled]
        source_type = "local"
        source = "/Users/brendondelgado/.codex/.tmp/bundled-marketplaces/openai-bundled"
        """.write(to: config, atomically: true, encoding: .utf8)

        CodexConfigRepair.repairDefaultConfigIfNeeded(
            configPath: config.path,
            removeStaleCopies: false,
            appMarketplacePath: unifiedMarketplacePath
        )

        let repaired = try String(contentsOf: config, encoding: .utf8)
        #expect(repaired.contains("source = \"\(unifiedMarketplacePath)\""))
    }

    @Test("Bundled plugin discovery repair creates marketplace and cache")
    func bundledPluginDiscoveryRepairCreatesMarketplaceAndCache() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "codex-bundled-plugin-repair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appMarketplace = tempDir.appending(path: "Codex.app/Contents/Resources/plugins/openai-bundled")
        try createFakeBundledPlugin(named: "browser-use", version: "0.1.0-alpha1", under: appMarketplace)
        try createFakeBundledPlugin(named: "computer-use", version: "1.0.758", under: appMarketplace)

        let codexHome = tempDir.appending(path: "home/.codex")
        let result = CodexConfigRepair.ensureBundledPluginDiscoveryIfNeeded(
            appMarketplacePath: appMarketplace.path,
            codexHome: codexHome.path
        )

        #expect(result.success)
        #expect(result.changed)
        #expect(FileManager.default.fileExists(atPath: codexHome.appending(path: ".agents/plugins/marketplace.json").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: codexHome.appending(path: "openai-bundled/current").path)) == appMarketplace.path)
        #expect(FileManager.default.fileExists(atPath: codexHome.appending(path: "plugins/cache/openai-bundled/browser-use/local/.codex-plugin/plugin.json").path))
        #expect(FileManager.default.fileExists(atPath: codexHome.appending(path: "plugins/cache/openai-bundled/computer-use/local/.codex-plugin/plugin.json").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(
            atPath: codexHome.appending(path: "plugins/cache/openai-bundled/computer-use/local/Codex Computer Use.app").path
        )) == appMarketplace.appending(path: "plugins/computer-use/Codex Computer Use.app").path)

        let secondResult = CodexConfigRepair.ensureBundledPluginDiscoveryIfNeeded(
            appMarketplacePath: appMarketplace.path,
            codexHome: codexHome.path
        )
        #expect(secondResult.success)
        #expect(!secondResult.changed)
    }

    private func createFakeBundledPlugin(named name: String, version: String, under marketplace: URL) throws {
        let plugin = marketplace.appending(path: "plugins/\(name)")
        try FileManager.default.createDirectory(
            at: plugin.appending(path: ".codex-plugin"),
            withIntermediateDirectories: true
        )
        if name == "computer-use" {
            try FileManager.default.createDirectory(
                at: plugin.appending(path: "Codex Computer Use.app"),
                withIntermediateDirectories: true
            )
        }
        try """
        {
          "name": "\(name)",
          "version": "\(version)",
          "description": "Fake \(name)"
        }
        """.write(
            to: plugin.appending(path: ".codex-plugin/plugin.json"),
            atomically: true,
            encoding: .utf8
        )
    }
}
