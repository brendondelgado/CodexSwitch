import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CodexSwitch

@Suite("Desktop archive authentication")
struct DesktopArchiveAuthenticationTests {
    @Test("A signature-only appcast release is canonicalized")
    func parserAcceptsSignatureOnlyRelease() throws {
        let signature = Data(repeating: 0x2a, count: 64).base64EncodedString()
        let xml = Data(
            """
            <rss><channel><item>
            <sparkle:shortVersionString>26.721.31836</sparkle:shortVersionString>
            <sparkle:version>5828</sparkle:version>
            <enclosure
              url="https://persistent.oaistatic.com/codex-app-prod/ChatGPT.zip"
              length="545070109"
              sparkle:edSignature="\(signature)" />
            </item></channel></rss>
            """.utf8
        )

        let release = try #require(
            CodexDesktopAppcastParser.latestRelease(from: xml)
        )
        #expect(release.archiveSHA256 == nil)
        #expect(release.archiveEdSignature == signature)
        #expect(release.archiveLength == 545_070_109)
    }

    @Test("Malformed Ed25519 metadata is rejected by the parser")
    func parserRejectsMalformedSignature() {
        let xml = Data(
            """
            <rss><channel><item>
            <sparkle:shortVersionString>26.721.31836</sparkle:shortVersionString>
            <sparkle:version>5828</sparkle:version>
            <enclosure
              url="https://persistent.oaistatic.com/codex-app-prod/ChatGPT.zip"
              sparkle:edSignature="not-a-signature" />
            </item></channel></rss>
            """.utf8
        )

        #expect(CodexDesktopAppcastParser.latestRelease(from: xml) == nil)
    }

    @Test("The exact archive bytes verify and produce a lifecycle SHA seal")
    func exactArchiveBytesVerify() throws {
        let bytes = Data("signed desktop archive".utf8)
        let signingKey = Curve25519.Signing.PrivateKey()
        let fixture = try archiveFixture(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let signature = try signingKey.signature(for: bytes).base64EncodedString()
        let release = release(
            signature: signature,
            length: Int64(bytes.count)
        )
        let retained = try DesktopPinnedRegularFile(
            url: fixture.archive,
            maximumBytes: 1_024
        )

        let evidence = try DesktopArchiveAuthenticator.verify(
            release: release,
            archive: retained,
            trustedEd25519PublicKey: signingKey.publicKey.rawRepresentation,
            isCancelled: { false }
        )

        #expect(evidence.contentSHA256 == SHA256.hash(data: bytes).hexString)
        #expect(evidence.ed25519Signature == signature)
        #expect(evidence.signingKeyID == DesktopArchiveAuthenticator.openAIProductionKeyID)
        #expect(evidence.byteCount == Int64(bytes.count))
    }

    @Test("Authenticated snapshot is an unlinked read-only independent inode")
    func authenticatedSnapshotIsPrivateAndIndependent() throws {
        let bytes = Data("signed immutable archive".utf8)
        let replacement = Data(repeating: 0x7a, count: bytes.count)
        let signingKey = Curve25519.Signing.PrivateKey()
        let fixture = try archiveFixture(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let retained = try DesktopPinnedRegularFile(
            url: fixture.archive,
            maximumBytes: 1_024
        )
        let snapshot = try DesktopPinnedRegularFile.privateSnapshot(
            copying: retained,
            in: fixture.root,
            maximumBytes: 1_024,
            isCancelled: { false }
        )

        var info = stat()
        #expect(fstat(snapshot.descriptor, &info) == 0)
        #expect(snapshot.isPrivateSnapshot)
        #expect(snapshot.identity != retained.identity)
        #expect(info.st_nlink == 0)
        #expect((info.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH)) == 0)
        #expect((info.st_flags & UInt32(UF_IMMUTABLE)) != 0)
        #expect((fcntl(snapshot.descriptor, F_GETFL) & O_ACCMODE) == O_RDONLY)

        let sourceDescriptor = open(
            fixture.archive.path,
            O_WRONLY | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(sourceDescriptor >= 0)
        defer { if sourceDescriptor >= 0 { _ = close(sourceDescriptor) } }
        let replacedBytes = replacement.withUnsafeBytes {
            pwrite(sourceDescriptor, $0.baseAddress, $0.count, 0)
        }
        #expect(replacedBytes == replacement.count)
        #expect(
            try snapshot.read(offset: 0, count: bytes.count) == bytes
        )

        var attemptedByte: UInt8 = 0
        #expect(pwrite(snapshot.descriptor, &attemptedByte, 1, 0) == -1)
        let signature = try signingKey.signature(for: bytes).base64EncodedString()
        let evidence = try DesktopArchiveAuthenticator.verify(
            release: release(
                signature: signature,
                length: Int64(bytes.count)
            ),
            archive: snapshot,
            trustedEd25519PublicKey: signingKey.publicKey.rawRepresentation,
            isCancelled: { false }
        )
        #expect(evidence.contentSHA256 == SHA256.hash(data: bytes).hexString)
    }

    @Test("A valid SHA cannot replace the required OpenAI signature")
    func shaOnlyReleaseIsRejected() throws {
        let bytes = Data("legacy digest only".utf8)
        let fixture = try archiveFixture(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let retained = try DesktopPinnedRegularFile(
            url: fixture.archive,
            maximumBytes: 1_024
        )
        let digest = SHA256.hash(data: bytes).hexString
        let unsigned = CodexDesktopAppRelease(
            shortVersion: "26.721.31836",
            bundleVersion: "5828",
            downloadURL: releaseURL,
            archiveSHA256: digest,
            archiveLength: Int64(bytes.count)
        )

        #expect(throws: DesktopDefinitiveReleaseRejection.self) {
            _ = try DesktopArchiveAuthenticator.verify(
                release: unsigned,
                archive: retained,
                trustedEd25519PublicKey: Data(repeating: 0, count: 32),
                isCancelled: { false }
            )
        }
    }

    @Test("Same-inode writes are observed by the retained file guard")
    func sameInodeMutationIsObserved() throws {
        let bytes = Data("original bytes".utf8)
        let fixture = try archiveFixture(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let retained = try DesktopPinnedRegularFile(
            url: fixture.archive,
            maximumBytes: 1_024
        )
        let guarder = try #require(
            DesktopRetainedFileMutationGuard(descriptor: retained.descriptor)
        )

        let descriptor = open(fixture.archive.path, O_WRONLY | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { if descriptor >= 0 { _ = close(descriptor) } }
        let replacement = Data("mutated bytes!".utf8)
        _ = replacement.withUnsafeBytes {
            pwrite(descriptor, $0.baseAddress, $0.count, 0)
        }

        #expect(guarder.observedMutation())
    }

    @Test("Reading an authenticated archive is not reported as mutation")
    func retainedArchiveReadsDoNotTriggerMutation() throws {
        let bytes = Data("authenticated archive bytes".utf8)
        let fixture = try archiveFixture(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let retained = try DesktopPinnedRegularFile(
            url: fixture.archive,
            maximumBytes: 1_024
        )
        let guarder = try #require(
            DesktopRetainedFileMutationGuard(descriptor: retained.descriptor)
        )

        _ = try retained.sha256(isCancelled: { false })
        _ = try retained.withMappedData { $0.count }

        #expect(!guarder.observedMutation())
    }

    @Test("Extraction input remains bound to the authenticated archive inode")
    func extractionInputUsesRetainedDescriptor() throws {
        let bytes = Data("authenticated archive".utf8)
        let fixture = try archiveFixture(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let retained = try DesktopPinnedRegularFile(
            url: fixture.archive,
            maximumBytes: 1_024
        )

        try FileManager.default.removeItem(at: fixture.archive)
        try Data("replacement archive".utf8).write(to: fixture.archive)

        let input = try retained.standardInputHandle()
        #expect(try input.readToEnd() == bytes)
        #expect(!retained.verifyPathIdentity())
    }

    @Test("The default ditto extractor consumes the retained descriptor")
    func defaultExtractorUsesRetainedDescriptor() throws {
        let fixture = try archiveFixture(bytes: Data())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent(
            "ChatGPT.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        let marker = source.appendingPathComponent("retained-marker")
        try Data("authenticated".utf8).write(to: marker)
        _ = try DesktopUpdaterProcessRunner().runChecked(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: [
                "-c",
                "-k",
                "--keepParent",
                source.path,
                fixture.archive.path,
            ],
            timeout: 30
        )
        let retained = try DesktopPinnedRegularFile(
            url: fixture.archive,
            maximumBytes: 10 * 1024 * 1024
        )
        try FileManager.default.removeItem(at: fixture.archive)
        try Data("replacement archive".utf8).write(to: fixture.archive)

        let destination = fixture.root.appendingPathComponent(
            "extracted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let downloader = DesktopUpdateDownloader(
            updateRoot: fixture.root.appendingPathComponent(
                "updates",
                isDirectory: true
            ),
            temporaryRoot: fixture.root.appendingPathComponent(
                "temporary",
                isDirectory: true
            ),
            availableCapacity: { 20 * 1024 * 1024 * 1024 }
        )

        try downloader.extractArchive(retained, destination, { false })

        #expect(
            try Data(
                contentsOf: destination
                    .appendingPathComponent("ChatGPT.app")
                    .appendingPathComponent("retained-marker")
            ) == Data("authenticated".utf8)
        )
    }

    @Test("A staged local SHA still matches the signed appcast payload")
    func stagedPayloadMatchesBySignature() {
        let signature = Data(repeating: 0x19, count: 64).base64EncodedString()
        let release = release(signature: signature, length: 42)
        let staged = CodexDesktopStagedUpdate(
            shortVersion: release.shortVersion,
            bundleVersion: release.bundleVersion,
            downloadURL: release.downloadURL,
            appPath: "/tmp/ChatGPT.app",
            stagedAt: Date(timeIntervalSince1970: 1),
            archiveSHA256: String(repeating: "a", count: 64),
            archiveEdSignature: signature,
            archiveLength: 42
        )

        #expect(staged.matches(release))
    }

    @Test("Desktop update activation intent remains durable until cleared")
    func activationIntentIsDurable() throws {
        let suiteName = "codexswitch-update-activation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let target = CodexDesktopUpdateActivationTarget(
            shortVersion: "26.721.31836",
            bundleVersion: "5828",
            appPath: "/Applications/ChatGPT.app"
        )
        CodexDesktopUpdateActivationIntent.markPending(
            target: target,
            defaults: defaults
        )
        #expect(CodexDesktopUpdateActivationIntent.isPending(defaults: defaults))
        #expect(
            CodexDesktopUpdateActivationIntent.pendingTarget(defaults: defaults)
                == target
        )
        CodexDesktopUpdateActivationIntent.clear(defaults: defaults)
        #expect(!CodexDesktopUpdateActivationIntent.isPending(defaults: defaults))
        #expect(
            CodexDesktopUpdateActivationIntent.pendingTarget(defaults: defaults)
                == nil
        )
    }

    private var releaseURL: URL {
        URL(
            string: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT.zip"
        )!
    }

    private func release(
        signature: String,
        length: Int64
    ) -> CodexDesktopAppRelease {
        CodexDesktopAppRelease(
            shortVersion: "26.721.31836",
            bundleVersion: "5828",
            downloadURL: releaseURL,
            archiveEdSignature: signature,
            archiveLength: length
        )
    }

    private func archiveFixture(
        bytes: Data
    ) throws -> (root: URL, archive: URL) {
        let root = CodexDesktopPathSecurity.canonicalSystemTemporaryDirectory()
            .appendingPathComponent(
            "codexswitch-archive-auth-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let archive = root.appendingPathComponent("ChatGPT.zip")
        try bytes.write(to: archive)
        return (root, archive)
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
