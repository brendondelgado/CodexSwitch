import Testing
@testable import CodexSwitch

@Suite("Desktop runtime diagnostics")
struct DesktopRuntimeDiagnosticsTests {
    @Test("pgrep parser separates desktop app-server from Homebrew vendor CLI app-server")
    func parsesDesktopAndVendorAppServers() {
        let output = """
        34109 /Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled
        80379 /Users/brendondelgado/Developer/codex/codex-rs/target/fork-release/codex app-server --analytics-default-enabled
        90722 /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex app-server --analytics-default-enabled
        """

        let processes = DesktopRuntimeDiagnostics.parseAppServerProcesses(fromPGrepOutput: output)

        #expect(processes.count == 3)
        #expect(processes[0].pid == 34109)
        #expect(processes[0].executablePath == "/Applications/Codex.app/Contents/Resources/codex")
        #expect(processes[0].classification == .desktopAppServer)
        #expect(processes[1].pid == 80379)
        #expect(processes[1].executablePath == "/Users/brendondelgado/Developer/codex/codex-rs/target/fork-release/codex")
        #expect(processes[1].classification == .desktopAppServer)
        #expect(processes[2].pid == 90722)
        #expect(processes[2].executablePath == "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex")
        #expect(processes[2].classification == .vendorCLIAppServer)
    }

    @Test("pgrep parser ignores launchers and unrelated processes")
    func ignoresNonAppServerProcessLines() {
        let output = """
        90660 node /opt/homebrew/bin/codex app-server --analytics-default-enabled
        70000 /Applications/Codex.app/Contents/Resources/codex resume --yolo
        70001 /Applications/CodexSwitch.app/Contents/MacOS/CodexSwitch
        70002 pgrep -fl codex app-server
        """

        let processes = DesktopRuntimeDiagnostics.parseAppServerProcesses(fromPGrepOutput: output)

        #expect(processes.count == 1)
        #expect(processes[0].classification == .vendorCLIAppServer)
    }

    @Test("lsof parser returns port for matching desktop app-server PID")
    func parsesPortForDesktopAppServerPID() {
        let output = """
        COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        codex   34109 user   12u  IPv4 0x123456789abcdef0      0t0  TCP 127.0.0.1:51234 (LISTEN)
        codex   90722 user   13u  IPv4 0x123456789abcdef1      0t0  TCP 127.0.0.1:61234 (LISTEN)
        """

        let port = DesktopRuntimeDiagnostics.parseWebSocketPort(
            fromLsofOutput: output,
            appServerPID: 34109
        )

        #expect(port == 51234)
    }

    @Test("lsof parser ignores non-listening and non-matching PID rows")
    func ignoresNonListeningAndWrongPIDRows() {
        let output = """
        COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        codex   34109 user   12u  IPv4 0x123456789abcdef0      0t0  TCP 127.0.0.1:51234 (ESTABLISHED)
        codex   90722 user   13u  IPv4 0x123456789abcdef1      0t0  TCP 127.0.0.1:61234 (LISTEN)
        """

        let port = DesktopRuntimeDiagnostics.parseWebSocketPort(
            fromLsofOutput: output,
            appServerPID: 34109
        )

        #expect(port == nil)
    }

    @Test("lsof parser does not guess unrelated Electron listener without app-server PID")
    func nilPIDDoesNotMatchUnrelatedElectronListener() {
        let output = """
        COMMAND    PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        Electron 55001 user   39u  IPv4 0x123456789abcdef0      0t0  TCP 127.0.0.1:45555 (LISTEN)
        """

        let port = DesktopRuntimeDiagnostics.parseWebSocketPort(
            fromLsofOutput: output,
            appServerPID: nil
        )

        #expect(port == nil)
    }
    @Test("desktop connector port discovery rejects vendor CLI app-server")
    func desktopConnectorPortDiscoveryRejectsVendorCLIAppServer() {
        let pgrepOutput = """
        90722 /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex app-server --analytics-default-enabled
        """
        let lsofOutput = """
        COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        codex   90722 user   13u  IPv4 0x123456789abcdef1      0t0  TCP 127.0.0.1:61234 (LISTEN)
        """

        let port = DesktopAppConnector.discoverPort(
            pgrepOutput: pgrepOutput,
            lsofOutput: lsofOutput
        )

        #expect(port == nil)
    }

    @Test("desktop connector port discovery returns desktop app-server port")
    func desktopConnectorPortDiscoveryReturnsDesktopAppServerPort() {
        let pgrepOutput = """
        34109 /Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled
        """
        let lsofOutput = """
        COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        codex   34109 user   12u  IPv4 0x123456789abcdef0      0t0  TCP 127.0.0.1:51234 (LISTEN)
        """

        let port = DesktopAppConnector.discoverPort(
            pgrepOutput: pgrepOutput,
            lsofOutput: lsofOutput
        )

        #expect(port == 51234)
    }

}
