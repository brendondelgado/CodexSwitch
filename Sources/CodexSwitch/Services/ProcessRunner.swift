import Darwin
import Foundation

struct ProcessRunnerOutput: Sendable {
    let stdout: String
    let stderr: String
    let terminationStatus: Int32
    let timedOut: Bool
}

enum ProcessRunner {
    static func run(
        executablePath: String,
        arguments: [String] = [],
        timeout: TimeInterval = 2,
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        captureStdout: Bool = true,
        captureStderr: Bool = true
    ) -> ProcessRunnerOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment

        let stdoutPipe = captureStdout ? Pipe() : nil
        let stderrPipe = captureStderr ? Pipe() : nil
        process.standardOutput = stdoutPipe ?? FileHandle.nullDevice
        process.standardError = stderrPipe ?? FileHandle.nullDevice

        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exitSignal.signal()
        }

        let readQueue = DispatchQueue(label: "com.codexswitch.process-runner", attributes: .concurrent)
        let readGroup = DispatchGroup()
        let stdoutBox = LockedData()
        let stderrBox = LockedData()

        do {
            try process.run()
        } catch {
            stdoutPipe?.fileHandleForReading.closeFile()
            stdoutPipe?.fileHandleForWriting.closeFile()
            stderrPipe?.fileHandleForReading.closeFile()
            stderrPipe?.fileHandleForWriting.closeFile()
            return nil
        }

        // Close the parent copy of the write ends immediately so EOF can reach our
        // readers when the child exits or is killed. Leaving these open strands
        // readDataToEndOfFile() threads and slowly wedges the app.
        stdoutPipe?.fileHandleForWriting.closeFile()
        stderrPipe?.fileHandleForWriting.closeFile()

        if let stdoutPipe {
            readGroup.enter()
            readQueue.async {
                stdoutBox.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }
        }

        if let stderrPipe {
            readGroup.enter()
            readQueue.async {
                stderrBox.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }
        }

        let didExit = exitSignal.wait(timeout: .now() + timeout) == .success
        var timedOut = false

        if !didExit {
            timedOut = true
            if process.isRunning {
                process.terminate()
                if exitSignal.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = exitSignal.wait(timeout: .now() + 0.5)
                }
            }
        }

        if readGroup.wait(timeout: .now() + 1) == .timedOut {
            stdoutPipe?.fileHandleForReading.closeFile()
            stderrPipe?.fileHandleForReading.closeFile()
            _ = readGroup.wait(timeout: .now() + 1)
        }

        stdoutPipe?.fileHandleForReading.closeFile()
        stderrPipe?.fileHandleForReading.closeFile()

        return ProcessRunnerOutput(
            stdout: String(data: stdoutBox.value, encoding: .utf8) ?? "",
            stderr: String(data: stderrBox.value, encoding: .utf8) ?? "",
            terminationStatus: process.terminationStatus,
            timedOut: timedOut
        )
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
