// Sources/CodexNative/AppServer/AppServerPortDiscovery.swift
import Foundation

enum AppServerPortDiscovery {
    /// Parse the WebSocket port from an app-server log line.
    /// The app-server prints "Listening on ws://127.0.0.1:PORT" to stderr on startup.
    static func parsePort(from line: String) -> UInt16? {
        // Match "ws://127.0.0.1:PORT" or "ws://0.0.0.0:PORT"
        guard let range = line.range(of: #"ws://[\d.]+:(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let match = line[range]
        guard let colonIdx = match.lastIndex(of: ":") else { return nil }
        let portStr = match[match.index(after: colonIdx)...]
        return UInt16(portStr)
    }
}
