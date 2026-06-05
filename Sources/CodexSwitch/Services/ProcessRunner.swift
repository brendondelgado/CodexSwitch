import Darwin
import Foundation

struct ProcessRunResult: Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool

    var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

enum ProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String] = [],
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdout = LockedData()
        let stderr = LockedData()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stdout.append(chunk)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stderr.append(chunk)
            }
        }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminated.signal()
        }

        do {
            try process.run()
        } catch {
            stopReading((stdoutPipe, stdout), (stderrPipe, stderr))
            return ProcessRunResult(
                terminationStatus: -1,
                stdout: stdout.value,
                stderr: Data(error.localizedDescription.utf8),
                timedOut: false
            )
        }

        let didExit = terminated.wait(timeout: .now() + timeout) == .success
        var timedOut = false

        if !didExit {
            timedOut = true
            process.terminate()
            if terminated.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
        }

        stopReading((stdoutPipe, stdout), (stderrPipe, stderr))

        let terminationStatus = process.isRunning ? Int32(-1) : process.terminationStatus

        return ProcessRunResult(
            terminationStatus: terminationStatus,
            stdout: stdout.value,
            stderr: stderr.value,
            timedOut: timedOut
        )
    }

    private static func stopReading(_ outputs: (Pipe, LockedData)...) {
        for (pipe, buffer) in outputs {
            pipe.fileHandleForReading.readabilityHandler = nil
            if let remaining = try? pipe.fileHandleForReading.readToEnd(), !remaining.isEmpty {
                // Handlers are asynchronous; drain any bytes delivered between
                // process exit and handler shutdown.
                buffer.append(remaining)
            }
            try? pipe.fileHandleForReading.close()
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.withLock { data }
    }

    func set(_ newValue: Data) {
        lock.withLock {
            data = newValue
        }
    }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
        }
    }
}
