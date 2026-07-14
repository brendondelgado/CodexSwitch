import Darwin
import Foundation
import Security

private final class DesktopBoundedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var didTruncate = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            let available = max(0, limit - storage.count)
            if available > 0 {
                storage.append(data.prefix(available))
            }
            if data.count > available {
                didTruncate = true
            }
        }
    }

    var snapshot: (data: Data, truncated: Bool) {
        lock.withLock { (storage, didTruncate) }
    }
}

private final class DesktopPipeDrainer: @unchecked Sendable {
    private let readLock = NSLock()
    private let buffer: DesktopBoundedDataBuffer

    init(limit: Int) {
        buffer = DesktopBoundedDataBuffer(limit: limit)
    }

    func start(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            readLock.withLock {
                buffer.append(handle.availableData)
            }
        }
    }

    func stop(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForWriting.close()
        readLock.withLock {
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            if flags >= 0 {
                _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
            }
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = bytes.withUnsafeMutableBytes { storage in
                    Darwin.read(descriptor, storage.baseAddress, storage.count)
                }
                guard count > 0 else { break }
                buffer.append(Data(bytes.prefix(Int(count))))
            }
        }
        try? pipe.fileHandleForReading.close()
    }

    var snapshot: (data: Data, truncated: Bool) { buffer.snapshot }
}

protocol DesktopUpdaterTerminableProcess: AnyObject {
    func requestGracefulTermination()
    func requestForcedTermination()
    func detachReaper()
}

struct DesktopUpdaterTerminationController {
    let gracefulWait: TimeInterval
    let forcedWait: TimeInterval

    init(gracefulWait: TimeInterval = 0.5, forcedWait: TimeInterval = 1) {
        self.gracefulWait = gracefulWait
        self.forcedWait = forcedWait
    }

    func stop(
        _ process: DesktopUpdaterTerminableProcess,
        waitForTermination: (TimeInterval) -> Bool
    ) -> Bool {
        process.requestGracefulTermination()
        if waitForTermination(gracefulWait) { return true }
        process.requestForcedTermination()
        if waitForTermination(forcedWait) { return true }
        process.detachReaper()
        return false
    }
}

private final class DesktopFoundationProcessLifecycle: DesktopUpdaterTerminableProcess {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func requestGracefulTermination() {
        process.terminate()
    }

    func requestForcedTermination() {
        let identifier = process.processIdentifier
        guard identifier > 0 else { return }
        _ = kill(-identifier, SIGKILL)
        _ = kill(identifier, SIGKILL)
    }

    func detachReaper() {
        let process = process
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
        }
    }
}

struct DesktopUpdaterProcessRunner: Sendable {
    static let defaultOutputLimit = 256 * 1024
    static let cancellationPollInterval: TimeInterval = 0.025

    func run(
        executableURL: URL,
        arguments: [String] = [],
        timeout: TimeInterval,
        outputLimit: Int = defaultOutputLimit,
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> CodexDesktopTrustCommandResult {
        if isCancelled() {
            return CodexDesktopTrustCommandResult(
                cancelled: true,
                terminationStatus: -1
            )
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdout = DesktopPipeDrainer(limit: outputLimit)
        let stderr = DesktopPipeDrainer(limit: outputLimit)
        stdout.start(stdoutPipe)
        stderr.start(stderrPipe)

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        if isCancelled() {
            stopReading(stdoutPipe, into: stdout)
            stopReading(stderrPipe, into: stderr)
            return CodexDesktopTrustCommandResult(
                cancelled: true,
                terminationStatus: -1
            )
        }
        do {
            try process.run()
            _ = setpgid(process.processIdentifier, process.processIdentifier)
        } catch {
            stopReading(stdoutPipe, into: stdout)
            stopReading(stderrPipe, into: stderr)
            return makeResult(
                process: process,
                stdout: stdout,
                stderr: stderr,
                timedOut: false,
                cancelled: false,
                launchError: error.localizedDescription
            )
        }

        let deadline = DispatchTime.now() + max(0, timeout)
        var timedOut = false
        var cancelled = false
        var didTerminate = false
        while !didTerminate {
            didTerminate = terminated.wait(
                timeout: .now() + Self.cancellationPollInterval
            ) == .success
            if didTerminate { break }
            if isCancelled() {
                cancelled = true
                break
            }
            if DispatchTime.now() >= deadline {
                timedOut = true
                break
            }
        }

        if !didTerminate {
            let lifecycle = DesktopFoundationProcessLifecycle(process: process)
            didTerminate = DesktopUpdaterTerminationController().stop(
                lifecycle,
                waitForTermination: { interval in
                    terminated.wait(timeout: .now() + interval) == .success
                }
            )
        }
        stopReading(stdoutPipe, into: stdout)
        stopReading(stderrPipe, into: stderr)
        return makeResult(
            process: process,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut,
            cancelled: cancelled,
            reaped: didTerminate
        )
    }

    @discardableResult
    func runChecked(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> String {
        let result = run(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            isCancelled: isCancelled
        )
        if result.cancelled { throw CancellationError() }
        guard result.reaped else {
            throw processError("Command could not be reaped within the termination bound")
        }
        guard !result.timedOut else {
            throw processError("Command timed out")
        }
        guard result.terminationStatus == 0 else {
            let output = [result.standardOutput, result.standardError]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw processError(output.isEmpty ? "Command failed" : output)
        }
        return result.standardOutput
    }

    private func stopReading(_ pipe: Pipe, into drainer: DesktopPipeDrainer) {
        drainer.stop(pipe)
    }

    private func makeResult(
        process: Process,
        stdout: DesktopPipeDrainer,
        stderr: DesktopPipeDrainer,
        timedOut: Bool,
        cancelled: Bool,
        launchError: String? = nil,
        reaped: Bool = true
    ) -> CodexDesktopTrustCommandResult {
        let stdoutSnapshot = stdout.snapshot
        var stderrSnapshot = stderr.snapshot
        if let launchError, stderrSnapshot.data.isEmpty {
            stderrSnapshot.data = Data(launchError.utf8)
        }
        return CodexDesktopTrustCommandResult(
            timedOut: timedOut,
            cancelled: cancelled,
            terminationStatus: launchError != nil || !reaped
                ? -1
                : process.terminationStatus,
            standardOutput: String(decoding: stdoutSnapshot.data, as: UTF8.self),
            standardError: String(decoding: stderrSnapshot.data, as: UTF8.self),
            stdoutTruncated: stdoutSnapshot.truncated,
            stderrTruncated: stderrSnapshot.truncated,
            reaped: reaped
        )
    }

    private func processError(_ message: String) -> NSError {
        NSError(
            domain: "DesktopUpdaterProcessRunner",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

enum CodexDesktopCodeSignatureValidation {
    static let transientAssessmentSubsystemError = "internal error in Code Signing subsystem"
    static let expectedTeamIdentifier = "2DC432GLL2"
    static let expectedBundleIdentifier = "com.openai.codex"

    static func validateTrust(
        strictVerification: () -> CodexDesktopTrustCommandResult,
        gatekeeperAssessment: () -> CodexDesktopTrustCommandResult,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> CodexDesktopBundleValidationResult {
        if isCancelled() { return .cancelled }
        let strictResult = classifyStrictVerification(strictVerification())
        guard strictResult == .valid else { return strictResult }
        if isCancelled() { return .cancelled }
        let assessment = classifyGatekeeperAssessment(gatekeeperAssessment())
        if isCancelled() { return .cancelled }
        return assessment
    }

    static func validateOfficialBundleTrust(
        strictVerification: () -> CodexDesktopTrustCommandResult,
        gatekeeperAssessment: () -> CodexDesktopTrustCommandResult,
        identityInspection: () -> CodexDesktopBundleValidationResult,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> CodexDesktopBundleValidationResult {
        let trustResult = validateTrust(
            strictVerification: strictVerification,
            gatekeeperAssessment: gatekeeperAssessment,
            isCancelled: isCancelled
        )
        guard trustResult == .valid else { return trustResult }
        if isCancelled() { return .cancelled }
        let identity = identityInspection()
        return isCancelled() ? .cancelled : identity
    }

    static func classifySigningIdentity(
        _ evidence: DesktopSigningIdentityEvidence,
        expectedBundleIdentifier: String = expectedBundleIdentifier
    ) -> CodexDesktopBundleValidationResult {
        guard evidence.appleAnchorSatisfied else {
            return .invalid("bundle signing requirement did not satisfy the Apple anchor")
        }
        guard evidence.teamIdentifiers == [expectedTeamIdentifier] else {
            return .invalid("bundle signing Team ID did not exactly match OpenAI")
        }
        guard evidence.bundleIdentifiers == [expectedBundleIdentifier] else {
            return .invalid("bundle signing identifier did not exactly match the expected app")
        }
        return .valid
    }

    static func classifyStrictVerification(
        _ result: CodexDesktopTrustCommandResult
    ) -> CodexDesktopBundleValidationResult {
        if result.cancelled { return .cancelled }
        if result.timedOut || !result.reaped || result.terminationStatus == -1 {
            return .unavailable("codesign verification did not complete")
        }
        guard result.terminationStatus == 0 else {
            return .invalid(
                "codesign verification exited with status \(result.terminationStatus)"
            )
        }
        return .valid
    }

    static func classifyGatekeeperAssessment(
        _ result: CodexDesktopTrustCommandResult
    ) -> CodexDesktopBundleValidationResult {
        if result.cancelled { return .cancelled }
        if !result.timedOut, result.reaped, result.terminationStatus == 0 {
            return .valid
        }
        let exactMessage = result.standardError
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == transientAssessmentSubsystemError
        if result.timedOut || !result.reaped || result.terminationStatus == -1 {
            return .unavailable("Gatekeeper assessment did not complete")
        }
        if exactMessage {
            return .unavailable(transientAssessmentSubsystemError)
        }
        return .invalid(
            "Gatekeeper assessment rejected bundle with status \(result.terminationStatus)"
        )
    }
}

struct DesktopSecuritySigningIdentityInspector: Sendable {
    func inspect(
        appURL: URL,
        expectedBundleIdentifier: String
    ) -> CodexDesktopBundleValidationResult {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            return .unavailable("Security.framework could not open the signed bundle")
        }

        let requirementText = "anchor apple generic "
            + "and certificate leaf[subject.OU] = \""
            + CodexDesktopCodeSignatureValidation.expectedTeamIdentifier
            + "\" and identifier \"\(expectedBundleIdentifier)\""
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            return .unavailable("Security.framework could not create the signing requirement")
        }

        let validationFlags = SecCSFlags(
            rawValue: UInt32(kSecCSCheckAllArchitectures)
                | UInt32(kSecCSCheckNestedCode)
                | UInt32(kSecCSStrictValidate)
                | UInt32(kSecCSRestrictSymlinks)
        )
        guard SecStaticCodeCheckValidity(staticCode, validationFlags, requirement)
                == errSecSuccess else {
            return .invalid("bundle did not satisfy the exact OpenAI designated requirement")
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [CFString: Any],
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String,
        let bundleIdentifier = information[kSecCodeInfoIdentifier] as? String else {
            return .unavailable("Security.framework signing information was incomplete")
        }

        return CodexDesktopCodeSignatureValidation.classifySigningIdentity(
            DesktopSigningIdentityEvidence(
                appleAnchorSatisfied: true,
                teamIdentifiers: [teamIdentifier],
                bundleIdentifiers: [bundleIdentifier]
            ),
            expectedBundleIdentifier: expectedBundleIdentifier
        )
    }
}

struct DesktopBundleTrustValidator: Sendable {
    let processRunner: DesktopUpdaterProcessRunner
    let identityInspector: DesktopSecuritySigningIdentityInspector

    init(
        processRunner: DesktopUpdaterProcessRunner = DesktopUpdaterProcessRunner(),
        identityInspector: DesktopSecuritySigningIdentityInspector =
            DesktopSecuritySigningIdentityInspector()
    ) {
        self.processRunner = processRunner
        self.identityInspector = identityInspector
    }

    func validate(
        appURL: URL,
        expectedBundleVersion: String,
        expectedShortVersion: String,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> CodexDesktopBundleValidationResult {
        if isCancelled() { return .cancelled }
        let sealDate = Date(timeIntervalSince1970: 0)
        guard let mutationGuard = DesktopBundleTreeMutationGuard(appURL: appURL),
              let baselineSeal = DesktopBundleTreeIntegrity.makeSeal(
                  appURL: appURL,
                  validatedAt: sealDate,
                  isCancelled: isCancelled
              ),
              CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(appURL),
              let install = CodexDesktopAppLocator.locate(appPath: appURL.path),
              install.bundleVersion == expectedBundleVersion,
              install.shortVersion == expectedShortVersion else {
            return .invalid("bundle structure, path, or version did not match the appcast")
        }
        if isCancelled() { return .cancelled }
        let result = CodexDesktopCodeSignatureValidation.validateOfficialBundleTrust(
            strictVerification: {
                processRunner.run(
                    executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                    arguments: [
                        "--verify", "--deep", "--strict", "--verbose=2", appURL.path,
                    ],
                    timeout: 30,
                    isCancelled: isCancelled
                )
            },
            gatekeeperAssessment: {
                processRunner.run(
                    executableURL: URL(fileURLWithPath: "/usr/sbin/spctl"),
                    arguments: [
                        "--assess", "--type", "execute", "--verbose=2", appURL.path,
                    ],
                    timeout: 30,
                    isCancelled: isCancelled
                )
            },
            identityInspection: {
                identityInspector.inspect(
                    appURL: appURL,
                    expectedBundleIdentifier: CodexDesktopCodeSignatureValidation
                        .expectedBundleIdentifier
                )
            },
            isCancelled: isCancelled
        )
        if isCancelled() || result == .cancelled { return .cancelled }
        guard !mutationGuard.observedMutation(),
              let finalSeal = DesktopBundleTreeIntegrity.makeSeal(
                  appURL: appURL,
                  validatedAt: sealDate,
                  isCancelled: isCancelled
              ),
              finalSeal == baselineSeal else {
            return isCancelled()
                ? .cancelled
                : .invalid("bundle tree identity or content changed during trust validation")
        }
        return result
    }

    static func rejectionClass(
        for result: CodexDesktopBundleValidationResult
    ) -> DesktopRejectedReleaseReasonClass? {
        guard case .invalid(let reason) = result else { return nil }
        if reason.contains("codesign verification") { return .strictSignature }
        if reason.contains("Gatekeeper") { return .gatekeeperRejection }
        if reason.contains("signing")
            || reason.contains("designated requirement")
            || reason.contains("Apple anchor") {
            return .signingIdentity
        }
        if reason.contains("version") { return .releaseMetadata }
        return .bundleStructure
    }
}
