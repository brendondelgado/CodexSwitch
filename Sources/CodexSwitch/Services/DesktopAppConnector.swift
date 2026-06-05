import Foundation
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "DesktopApp")

/// Connects to a running Codex desktop app via its local WebSocket server
/// and injects auth tokens using the JSON-RPC `account/login/start` method.
enum DesktopAppConnector {
    private nonisolated static let authWatcherReadyPath =
        NSString("~/.codexswitch/desktop-auth-watcher-ready").expandingTildeInPath

    nonisolated static func authWatcherReady() -> Bool {
        FileManager.default.fileExists(atPath: authWatcherReadyPath)
    }

    /// Discover the WebSocket port of a running Codex app-server.
    /// The app-server binds to 127.0.0.1 on a dynamic port.
    nonisolated static func discoverPort() -> UInt16? {
        let pgrepResult = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-fl", "codex.*app-server"],
            timeout: 3
        )
        guard !pgrepResult.timedOut, pgrepResult.terminationStatus == 0 else {
            logger.debug("pgrep failed or timed out while discovering Codex app-server")
            return nil
        }

        let lsofResult = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-iTCP", "-sTCP:LISTEN", "-P", "-n"],
            timeout: 3
        )
        guard !lsofResult.timedOut, lsofResult.terminationStatus == 0 else {
            logger.debug("lsof failed or timed out while discovering Codex app-server")
            return nil
        }

        let port = discoverPort(
            pgrepOutput: pgrepResult.stdoutString,
            lsofOutput: lsofResult.stdoutString
        )
        if let port {
            logger.info("Found Codex desktop app-server on port \(port)")
        } else {
            logger.debug("No Codex desktop app-server found listening")
        }
        return port
    }


    nonisolated static func discoverPort(pgrepOutput: String, lsofOutput: String) -> UInt16? {
        let desktopPID = DesktopRuntimeDiagnostics
            .parseAppServerProcesses(fromPGrepOutput: pgrepOutput)
            .first { $0.classification == .desktopAppServer }?
            .pid
        guard let desktopPID else { return nil }
        return DesktopRuntimeDiagnostics.parseWebSocketPort(
            fromLsofOutput: lsofOutput,
            appServerPID: desktopPID
        )
    }

    /// Inject auth tokens into the running Codex desktop app via WebSocket JSON-RPC.
    /// Returns true on success.
    static func injectTokens(
        accessToken: String,
        refreshToken: String = "",
        idToken: String = "",
        chatgptAccountId: String,
        planType: String?,
        port: UInt16
    ) async -> Bool {
        let account = CodexAccount(
            email: "",
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: chatgptAccountId,
            planType: planType
        )
        let result = await DesktopRuntimeReloadClient(port: port).reloadAuth(account: account, port: port)
        switch result {
        case .reloaded(let method):
            logger.info("Desktop app auth reload succeeded via \(method, privacy: .public)")
            return true
        case .unsupported:
            logger.warning("Desktop app auth reload unsupported")
            return false
        case .noDesktopRuntime:
            logger.debug("No desktop runtime available for auth reload")
            return false
        case .failed(let reason):
            logger.error("Desktop app auth reload failed: \(reason, privacy: .public)")
            return false
        }
    }

    /// Try to inject tokens into any running Codex desktop app instance.
    /// Returns true if a desktop app was found and tokens were injected.
    static func tryInjectTokens(for account: CodexAccount) async -> Bool {
        guard let port = discoverPort() else {
            let patchStatus = DesktopPatchManager.currentStatus()
            guard patchStatus.isCodexAppRunning else {
                logger.debug("No Codex desktop app running — skipping injection")
                return false
            }

            if DesktopPatchManager.runtimeHotSwapState() == .restartRequired {
                logger.warning("Codex desktop app is running a stale bundled CLI; restart Codex.app to activate hot-swap")
                return false
            }

            if authWatcherReady() {
                if SwapEngine.signalDesktopAppServerReload() {
                    logger.info("Codex desktop auth watcher marker exists; reloaded app-server via SIGHUP")
                    return true
                }
                logger.warning("Codex desktop auth watcher marker exists, but no app-server port was found; not claiming desktop reload success")
                return false
            }

            if SwapEngine.signalDesktopAppServerReload() {
                logger.info("Codex desktop app-server reloaded via SIGHUP")
                return true
            }

            logger.warning("Codex desktop app is running, but external reload is unavailable")
            return false
        }

        return await injectTokens(
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            idToken: account.idToken,
            chatgptAccountId: account.accountId,
            planType: account.planType,
            port: port
        )
    }
}
