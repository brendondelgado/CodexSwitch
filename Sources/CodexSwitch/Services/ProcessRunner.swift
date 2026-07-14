import Darwin
import Foundation

struct ProcessRunResult: Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
    let stdoutTruncated: Bool
    let stderrTruncated: Bool

    init(
        terminationStatus: Int32,
        stdout: Data,
        stderr: Data,
        timedOut: Bool,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }

    var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

enum ProcessRunner {
    static let defaultOutputLimit = 1024 * 1024

    static func run(
        executableURL: URL,
        arguments: [String] = [],
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        maxOutputBytes: Int = defaultOutputLimit
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

        let outputLimit = max(0, maxOutputBytes)
        let stdout = PipeDrainer(pipe: stdoutPipe, retentionLimit: outputLimit)
        let stderr = PipeDrainer(pipe: stderrPipe, retentionLimit: outputLimit)

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminated.signal()
        }

        do {
            try process.run()
        } catch {
            stdout.close()
            stderr.close()
            return ProcessRunResult(
                terminationStatus: -1,
                stdout: Data(),
                stderr: Data(error.localizedDescription.utf8),
                timedOut: false
            )
        }

        stdout.start()
        stderr.start()

        let didExit = terminated.wait(timeout: .now() + max(0, timeout)) == .success
        var timedOut = false

        if !didExit {
            timedOut = true
            process.terminate()
            if terminated.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
        }

        stdout.finish()
        stderr.finish()

        let terminationStatus = process.isRunning ? Int32(-1) : process.terminationStatus
        let stdoutSnapshot = stdout.snapshot
        let stderrSnapshot = stderr.snapshot

        return ProcessRunResult(
            terminationStatus: terminationStatus,
            stdout: stdoutSnapshot.data,
            stderr: stderrSnapshot.data,
            timedOut: timedOut,
            stdoutTruncated: stdoutSnapshot.truncated,
            stderrTruncated: stderrSnapshot.truncated
        )
    }
}

private final class PipeDrainer: @unchecked Sendable {
    private let pipe: Pipe
    private let buffer: BoundedData
    private let finished = DispatchSemaphore(value: 0)

    init(pipe: Pipe, retentionLimit: Int) {
        self.pipe = pipe
        self.buffer = BoundedData(limit: retentionLimit)
    }

    var snapshot: (data: Data, truncated: Bool) {
        buffer.snapshot
    }

    func start() {
        try? pipe.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { finished.signal() }
            do {
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024),
                      !chunk.isEmpty {
                    buffer.append(chunk)
                }
            } catch {
                // Closing the reader is the bounded cancellation path when a
                // descendant retains an inherited pipe after the child exits.
            }
        }
    }

    func finish() {
        if finished.wait(timeout: .now() + 1) == .timedOut {
            try? pipe.fileHandleForReading.close()
            _ = finished.wait(timeout: .now() + 0.1)
        } else {
            try? pipe.fileHandleForReading.close()
        }
    }

    func close() {
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
    }
}

private final class BoundedData: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    var snapshot: (data: Data, truncated: Bool) {
        lock.withLock { (data, truncated) }
    }

    func append(_ chunk: Data) {
        lock.withLock {
            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                truncated = true
            }
        }
    }
}
