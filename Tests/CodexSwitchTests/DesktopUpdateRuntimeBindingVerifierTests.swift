import Darwin
import Foundation
import Testing
@testable import CodexSwitch

@Suite("Desktop update runtime binding verifier")
struct DesktopUpdateRuntimeBindingVerifierTests {
    @Test("Fresh runtime acknowledgement is bound to the installed ChatGPT host")
    func acceptsInstalledHostConnection() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let acknowledged = DesktopUpdateRuntimeBindingVerifier.acknowledgesInstalledHost(
            result: fixture.reloadResult,
            appPath: fixture.appPath,
            hostProcesses: [fixture.host],
            requiredOwnerUID: 501,
            processIdentity: { pid in
                fixture.processIdentities[pid]
            },
            kernelExecutableIdentity: { pid in
                fixture.identities[pid]
            },
            runtimeTargetIsCurrent: { target, requiredOwnerUID in
                requiredOwnerUID == 501
                    && fixture.processIdentities[
                        target.process.identity.pid
                    ] == target.process.identity
            },
            runtimeOwnsListeningPort: { _ in true },
            establishedConnections: { pid in
                fixture.connectionsByPID[pid] ?? []
            }
        )
        #expect(acknowledged)
    }

    @Test("Unrelated prepared app-server cannot satisfy target activation")
    func rejectsUnconnectedPreparedRuntime() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let acknowledged = DesktopUpdateRuntimeBindingVerifier.acknowledgesInstalledHost(
            result: fixture.reloadResult,
            appPath: fixture.appPath,
            hostProcesses: [fixture.host],
            requiredOwnerUID: 501,
            processIdentity: { pid in
                fixture.processIdentities[pid]
            },
            kernelExecutableIdentity: { pid in
                fixture.identities[pid]
            },
            runtimeTargetIsCurrent: { target, requiredOwnerUID in
                requiredOwnerUID == 501
                    && fixture.processIdentities[
                        target.process.identity.pid
                    ] == target.process.identity
            },
            runtimeOwnsListeningPort: { _ in true },
            establishedConnections: { pid in
                pid == fixture.host.pid
                    ? fixture.connectionsByPID[pid] ?? []
                    : []
            }
        )
        #expect(!acknowledged)
    }

    @Test("Host argv path cannot replace kernel executable identity")
    func rejectsWrongHostKernelIdentity() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let acknowledged = DesktopUpdateRuntimeBindingVerifier.acknowledgesInstalledHost(
            result: fixture.reloadResult,
            appPath: fixture.appPath,
            hostProcesses: [fixture.host],
            requiredOwnerUID: 501,
            processIdentity: { pid in
                fixture.processIdentities[pid]
            },
            kernelExecutableIdentity: { pid in
                if pid == fixture.host.pid {
                    return CodexKernelExecutableIdentity(
                        canonicalPath: fixture.host.executablePath,
                        device: 91,
                        inode: 92
                    )
                }
                return fixture.identities[pid]
            },
            runtimeTargetIsCurrent: { target, requiredOwnerUID in
                requiredOwnerUID == 501
                    && fixture.processIdentities[
                        target.process.identity.pid
                    ] == target.process.identity
            },
            runtimeOwnsListeningPort: { _ in true },
            establishedConnections: { pid in
                fixture.connectionsByPID[pid] ?? []
            }
        )
        #expect(!acknowledged)
    }

    @Test("A listener port handoff cannot inherit an unrelated established connection")
    func rejectsPortHandoffWithoutMatchingPeerTuple() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let hostConnection = fixture.connectionsByPID[fixture.host.pid]!
        let runtimePID = fixture.runtimePID
        let wrongRuntimeConnection = Set(hostConnection.map { connection in
            DesktopLoopbackTCPConnection(
                local: connection.remote,
                remote: DesktopLoopbackTCPEndpoint(
                    host: connection.local.host,
                    port: connection.local.port + 1
                )
            )
        })

        let acknowledged = DesktopUpdateRuntimeBindingVerifier.acknowledgesInstalledHost(
            result: fixture.reloadResult,
            appPath: fixture.appPath,
            hostProcesses: [fixture.host],
            requiredOwnerUID: 501,
            processIdentity: { fixture.processIdentities[$0] },
            kernelExecutableIdentity: { fixture.identities[$0] },
            runtimeTargetIsCurrent: { target, requiredOwnerUID in
                requiredOwnerUID == 501
                    && fixture.processIdentities[
                        target.process.identity.pid
                    ] == target.process.identity
            },
            runtimeOwnsListeningPort: { _ in true },
            establishedConnections: { pid in
                pid == runtimePID
                    ? wrongRuntimeConnection
                    : fixture.connectionsByPID[pid] ?? []
            }
        )
        #expect(!acknowledged)
    }

    @Test("Same-PID host restart cannot reuse captured activation evidence")
    func rejectsHostPIDReuse() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var hostIdentityReads = 0

        let acknowledged = DesktopUpdateRuntimeBindingVerifier.acknowledgesInstalledHost(
            result: fixture.reloadResult,
            appPath: fixture.appPath,
            hostProcesses: [fixture.host],
            requiredOwnerUID: 501,
            processIdentity: { pid in
                guard pid == fixture.host.pid else {
                    return fixture.processIdentities[pid]
                }
                hostIdentityReads += 1
                guard hostIdentityReads == 1 else {
                    let captured = fixture.host.processIdentity
                    return CodexSignalProcessIdentity(
                        pid: captured.pid,
                        ownerUID: captured.ownerUID,
                        executablePath: captured.executablePath,
                        startSeconds: captured.startSeconds + 1,
                        startMicroseconds: captured.startMicroseconds
                    )
                }
                return fixture.host.processIdentity
            },
            kernelExecutableIdentity: { fixture.identities[$0] },
            runtimeTargetIsCurrent: { _, _ in true },
            runtimeOwnsListeningPort: { _ in true },
            establishedConnections: { fixture.connectionsByPID[$0] ?? [] }
        )
        #expect(!acknowledged)
    }

    @Test("Same-PID app-server restart cannot inherit a stale acknowledgement")
    func rejectsRuntimePIDReuse() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var runtimeChecks = 0

        let acknowledged = DesktopUpdateRuntimeBindingVerifier.acknowledgesInstalledHost(
            result: fixture.reloadResult,
            appPath: fixture.appPath,
            hostProcesses: [fixture.host],
            requiredOwnerUID: 501,
            processIdentity: { fixture.processIdentities[$0] },
            kernelExecutableIdentity: { fixture.identities[$0] },
            runtimeTargetIsCurrent: { _, _ in
                runtimeChecks += 1
                return runtimeChecks < 3
            },
            runtimeOwnsListeningPort: { _ in true },
            establishedConnections: { fixture.connectionsByPID[$0] ?? [] }
        )
        #expect(!acknowledged)
    }

    @Test("Only complete established loopback tuples are parsed")
    func parsesEstablishedLoopbackConnections() {
        let output = """
        p101
        n127.0.0.1:60123->127.0.0.1:9223
        n[::1]:60124->[::1]:9334
        n10.0.0.8:60125->10.0.0.9:9445
        n127.0.0.1:60126
        """

        let expected: Set<DesktopLoopbackTCPConnection> = [
            DesktopLoopbackTCPConnection(
                local: .init(host: "127.0.0.1", port: 60_123),
                remote: .init(host: "127.0.0.1", port: 9_223)
            ),
            DesktopLoopbackTCPConnection(
                local: .init(host: "::1", port: 60_124),
                remote: .init(host: "::1", port: 9_334)
            ),
        ]
        #expect(
            DesktopUpdateRuntimeBindingVerifier
                .parseEstablishedLoopbackConnections(fromLsofFieldOutput: output)
                == expected
        )
    }

    @Test("Only loopback listener fields authorize the acknowledged endpoint")
    func parsesLoopbackListeningPorts() {
        let output = """
        p202
        n127.0.0.1:9223
        n[::1]:9334
        n*:9445
        n127.0.0.1:9556->127.0.0.1:9667
        """

        #expect(
            DesktopUpdateRuntimeBindingVerifier
                .parseLoopbackListeningPorts(fromLsofFieldOutput: output)
                == [9_223, 9_334]
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswitch-runtime-binding-\(UUID().uuidString)")
        let app = root.appendingPathComponent("ChatGPT.app")
        let executable = app.appendingPathComponent("Contents/MacOS/ChatGPT")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executable)

        let canonicalAppPath = try canonicalPath(app.path)
        let canonicalExecutablePath = try canonicalPath(executable.path)
        let hostIdentity = try fileIdentity(canonicalExecutablePath)
        let hostPID: Int32 = 101
        let runtimePID: Int32 = 202
        let hostProcessIdentity = CodexSignalProcessIdentity(
            pid: hostPID,
            ownerUID: 501,
            executablePath: canonicalExecutablePath,
            startSeconds: 900,
            startMicroseconds: 4
        )
        let runtimeIdentity = CodexKernelExecutableIdentity(
            canonicalPath: "/private/tmp/prepared-codex",
            device: 7,
            inode: 8
        )
        let runtimeProcessIdentity = CodexSignalProcessIdentity(
            pid: runtimePID,
            ownerUID: 501,
            executablePath: runtimeIdentity.canonicalPath,
            startSeconds: 1_000,
            startMicroseconds: 5
        )
        let target = CodexRuntimeTarget(
            process: CodexIdentityBoundProcess(
                identity: runtimeProcessIdentity,
                kernelExecutableIdentity: runtimeIdentity,
                arguments: [runtimeIdentity.canonicalPath, "app-server"]
            ),
            runtimeKind: .externalAppServer
        )
        let port: UInt16 = 9_223
        let binding = CodexDesktopRuntimeSocketBinding(target: target, port: port)
        let hostConnection = DesktopLoopbackTCPConnection(
            local: .init(host: "127.0.0.1", port: 60_123),
            remote: .init(host: "127.0.0.1", port: port)
        )

        return Fixture(
            root: root,
            appPath: canonicalAppPath,
            host: DesktopUpdateHostProcess(
                processIdentity: hostProcessIdentity
            ),
            runtimePID: runtimePID,
            port: port,
            reloadResult: .reloaded(
                method: "account/login/start",
                discoveredRuntimeCount: 1,
                acknowledgedRuntimeCount: 1,
                acknowledgedRuntimeBindings: [binding]
            ),
            identities: [
                hostPID: hostIdentity,
                runtimePID: runtimeIdentity,
            ],
            processIdentities: [
                hostPID: hostProcessIdentity,
                runtimePID: runtimeProcessIdentity,
            ],
            connectionsByPID: [
                hostPID: [hostConnection],
                runtimePID: [hostConnection.reversed],
            ]
        )
    }

    private func canonicalPath(_ path: String) throws -> String {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &resolved) != nil else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard let terminator = resolved.firstIndex(of: 0) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return String(
            decoding: resolved[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private func fileIdentity(_ path: String) throws -> CodexKernelExecutableIdentity {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return CodexKernelExecutableIdentity(
            canonicalPath: path,
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    private struct Fixture {
        let root: URL
        let appPath: String
        let host: DesktopUpdateHostProcess
        let runtimePID: Int32
        let port: UInt16
        let reloadResult: DesktopReloadResult
        let identities: [Int32: CodexKernelExecutableIdentity]
        let processIdentities: [Int32: CodexSignalProcessIdentity]
        let connectionsByPID: [Int32: Set<DesktopLoopbackTCPConnection>]
    }
}
