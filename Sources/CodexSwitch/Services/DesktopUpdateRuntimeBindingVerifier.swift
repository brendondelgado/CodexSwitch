import Darwin
import Foundation

struct DesktopUpdateHostProcess: Equatable, Sendable {
    let processIdentity: CodexSignalProcessIdentity

    var pid: Int32 { processIdentity.pid }
    var executablePath: String { processIdentity.executablePath }
}

struct DesktopLoopbackTCPEndpoint: Hashable, Sendable {
    let host: String
    let port: UInt16
}

struct DesktopLoopbackTCPConnection: Hashable, Sendable {
    let local: DesktopLoopbackTCPEndpoint
    let remote: DesktopLoopbackTCPEndpoint

    var reversed: DesktopLoopbackTCPConnection {
        DesktopLoopbackTCPConnection(local: remote, remote: local)
    }
}

enum DesktopUpdateRuntimeBindingVerifier {
    nonisolated static func acknowledgesInstalledHost(
        result: DesktopReloadResult,
        appPath: String,
        hostProcesses: [DesktopUpdateHostProcess],
        requiredOwnerUID: UInt32 = geteuid(),
        processIdentity: (Int32) -> CodexSignalProcessIdentity? = {
            SwapEngine.signalProcessIdentity(pid: $0)
        },
        kernelExecutableIdentity: (Int32) -> CodexKernelExecutableIdentity? = {
            SwapEngine.kernelExecutableIdentity(pid: $0)
        },
        runtimeTargetIsCurrent: (CodexRuntimeTarget, UInt32) -> Bool = {
            SwapEngine.runtimeTargetIsCurrent(
                $0,
                requiredOwnerUID: $1
            )
        },
        runtimeOwnsListeningPort: (CodexDesktopRuntimeSocketBinding) -> Bool = {
            ownsLoopbackListeningPort(binding: $0)
        },
        establishedConnections: (Int32) -> Set<DesktopLoopbackTCPConnection> = {
            establishedLoopbackConnections(pid: $0)
        }
    ) -> Bool {
        guard case .reloaded(
            _,
            let discoveredRuntimeCount,
            let acknowledgedRuntimeCount,
            let acknowledgedBindings
        ) = result,
              discoveredRuntimeCount > 0,
              acknowledgedRuntimeCount == discoveredRuntimeCount,
              acknowledgedBindings.count == acknowledgedRuntimeCount,
              !acknowledgedBindings.isEmpty,
              let canonicalAppPath = canonicalExistingPath(appPath) else {
            return false
        }

        let currentBindings = acknowledgedBindings.filter { binding in
            runtimeTargetIsCurrent(binding.target, requiredOwnerUID)
                && runtimeOwnsListeningPort(binding)
        }
        guard currentBindings.count == acknowledgedBindings.count else {
            return false
        }

        return hostProcesses.contains { host in
            guard let canonicalExecutablePath = canonicalExistingPath(
                host.executablePath
            ),
                  host.processIdentity.ownerUID == requiredOwnerUID,
                  processIdentity(host.pid) == host.processIdentity,
                  executableBelongsToApp(
                      executablePath: canonicalExecutablePath,
                      appPath: canonicalAppPath
                  ),
                  let initialHostIdentity = kernelExecutableIdentity(host.pid),
                  initialHostIdentity.canonicalPath == canonicalExecutablePath,
                  fileIdentity(at: canonicalExecutablePath) == initialHostIdentity else {
                return false
            }

            let hostConnections = establishedConnections(host.pid)
            guard processIdentity(host.pid) == host.processIdentity,
                  kernelExecutableIdentity(host.pid) == initialHostIdentity,
                  fileIdentity(at: canonicalExecutablePath) == initialHostIdentity else {
                return false
            }
            return currentBindings.contains { binding in
                guard runtimeTargetIsCurrent(binding.target, requiredOwnerUID),
                      runtimeOwnsListeningPort(binding) else {
                    return false
                }
                let runtimeConnections = establishedConnections(
                    binding.target.process.identity.pid
                )
                guard processIdentity(host.pid) == host.processIdentity,
                      kernelExecutableIdentity(host.pid) == initialHostIdentity,
                      fileIdentity(at: canonicalExecutablePath) == initialHostIdentity,
                      runtimeTargetIsCurrent(binding.target, requiredOwnerUID),
                      runtimeOwnsListeningPort(binding) else {
                    return false
                }
                return hostConnections.contains { connection in
                    connection.remote.port == binding.port
                        && runtimeConnections.contains(connection.reversed)
                }
            }
        }
    }

    nonisolated static func parseEstablishedLoopbackConnections(
        fromLsofFieldOutput output: String
    ) -> Set<DesktopLoopbackTCPConnection> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard line.first == "n",
                  let arrow = line.range(of: "->") else {
                return nil
            }
            let localEndpoint = String(
                line[line.index(after: line.startIndex)..<arrow.lowerBound]
            )
            let remoteEndpoint = String(line[arrow.upperBound...])
            guard let local = loopbackEndpoint(from: localEndpoint),
                  let remote = loopbackEndpoint(from: remoteEndpoint) else {
                return nil
            }
            return DesktopLoopbackTCPConnection(local: local, remote: remote)
        })
    }

    nonisolated static func parseLoopbackListeningPorts(
        fromLsofFieldOutput output: String
    ) -> Set<UInt16> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard line.first == "n",
                  !line.contains("->") else {
                return nil
            }
            return loopbackEndpoint(from: String(line.dropFirst()))?.port
        })
    }

    private nonisolated static func ownsLoopbackListeningPort(
        binding: CodexDesktopRuntimeSocketBinding
    ) -> Bool {
        let pid = binding.target.process.identity.pid
        guard pid > 0 else { return false }
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: [
                "-nP",
                "-a",
                "-p",
                String(pid),
                "-iTCP:\(binding.port)",
                "-sTCP:LISTEN",
                "-Fn",
            ],
            timeout: 3
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return false
        }
        return parseLoopbackListeningPorts(
            fromLsofFieldOutput: result.stdoutString
        ).contains(binding.port)
    }

    private nonisolated static func establishedLoopbackConnections(
        pid: Int32
    ) -> Set<DesktopLoopbackTCPConnection> {
        guard pid > 0 else { return [] }
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: [
                "-nP",
                "-a",
                "-p",
                String(pid),
                "-iTCP",
                "-sTCP:ESTABLISHED",
                "-Fn",
            ],
            timeout: 3
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return []
        }
        return parseEstablishedLoopbackConnections(
            fromLsofFieldOutput: result.stdoutString
        )
    }

    private nonisolated static func loopbackEndpoint(
        from endpoint: String
    ) -> DesktopLoopbackTCPEndpoint? {
        guard let endpointToken = endpoint.split(
            whereSeparator: \.isWhitespace
        ).first else {
            return nil
        }
        let trimmed = String(endpointToken)
        let host: String
        let portText: Substring

        if trimmed.hasPrefix("["),
           let bracket = trimmed.firstIndex(of: "]"),
           trimmed.index(after: bracket) < trimmed.endIndex,
           trimmed[trimmed.index(after: bracket)] == ":" {
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<bracket])
            portText = trimmed[trimmed.index(bracket, offsetBy: 2)...]
        } else {
            guard let colon = trimmed.lastIndex(of: ":") else { return nil }
            host = String(trimmed[..<colon])
            portText = trimmed[trimmed.index(after: colon)...]
        }

        guard host == "127.0.0.1" || host == "::1",
              let port = UInt16(portText),
              port > 0 else {
            return nil
        }
        return DesktopLoopbackTCPEndpoint(host: host, port: port)
    }

    private nonisolated static func executableBelongsToApp(
        executablePath: String,
        appPath: String
    ) -> Bool {
        let executableDirectory = appPath + "/Contents/MacOS/"
        guard executablePath.hasPrefix(executableDirectory) else { return false }
        let relativePath = executablePath.dropFirst(executableDirectory.count)
        return !relativePath.isEmpty && !relativePath.contains("/")
    }

    private nonisolated static func canonicalExistingPath(
        _ path: String
    ) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &resolved) != nil else { return nil }
        guard let terminator = resolved.firstIndex(of: 0) else { return nil }
        return String(
            decoding: resolved[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private nonisolated static func fileIdentity(
        at path: String
    ) -> CodexKernelExecutableIdentity? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_dev > 0,
              metadata.st_ino > 0 else {
            return nil
        }
        return CodexKernelExecutableIdentity(
            canonicalPath: path,
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }
}
