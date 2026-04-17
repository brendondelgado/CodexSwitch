// Tests/CodexNativeTests/AppServerManagerTests.swift
import Testing
@testable import CodexNative

@Test("Parse WebSocket port from app-server stderr")
func parsePort() {
    // The app-server prints "Listening on ws://127.0.0.1:PORT" to stderr
    let line = "Listening on ws://127.0.0.1:54321"
    let port = AppServerPortDiscovery.parsePort(from: line)
    #expect(port == 54321)
}

@Test("Parse port returns nil for non-matching lines")
func parsePortNonMatch() {
    let port = AppServerPortDiscovery.parsePort(from: "Some other log line")
    #expect(port == nil)
}
