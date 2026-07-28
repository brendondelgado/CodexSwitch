import Darwin
import Foundation

enum CodexManagedRuntimeTrust {
    private static let maximumRuntimeBytes: Int64 = 512 * 1024 * 1024
    private static let maximumHelperBytes: Int64 = 128 * 1024 * 1024
    private static let maximumControlPlaneBytes: Int64 = 64 * 1024 * 1024
    private static let maximumManifestBytes: Int64 = 64 * 1024
    private static let artifactFormat = "codexswitch-macos-runtime-artifact-v1"

    private struct ArtifactManifest: Decodable {
        let format: String
        let codexSwitchGitSha: String
        let upstreamCodexVersion: String
        let sourcePatchSha256: String
        let architecture: String
        let buildEpoch: Int64
        let files: [ArtifactFile]
    }

    private struct ArtifactFile: Decodable {
        let name: String
        let bytes: Int64
        let sha256: String
    }

    enum Failure: String, Error, Sendable {
        case managedRouteUnverified = "managed_route_unverified"
        case runtimeHashUnverified = "runtime_hash_unverified"
        case helperHashUnverified = "helper_hash_unverified"
    }

    struct VerifiedRoute: Equatable, Sendable {
        let route: CodexVersionChecker.ManagedRuntimeRoute
        let runtimeIdentity: DesktopInstallPathIdentity
    }

    static func defaultManagedLauncherPath(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        homeDirectory.appendingPathComponent(
            ".local/share/codexswitch/patched-codex/codex"
        ).path
    }

    static func verifyRoute(
        managedLauncherPath: String
    ) -> Result<VerifiedRoute, Failure> {
        guard let route = CodexVersionChecker.managedRuntimeRoute(
            managedLauncherPath: managedLauncherPath
        ) else {
            return .failure(.managedRouteUnverified)
        }
        guard let runtimeIdentity = verifiedReadOnlyFile(
            at: route.runtimePath,
            expectedSHA256: route.runtimeSHA256,
            maximumBytes: maximumRuntimeBytes
        ) else {
            return .failure(.runtimeHashUnverified)
        }
        guard verifiedReadOnlyFile(
            at: route.helperPath,
            expectedSHA256: route.helperSHA256,
            maximumBytes: maximumHelperBytes
        ) != nil else {
            return .failure(.helperHashUnverified)
        }
        return .success(VerifiedRoute(
            route: route,
            runtimeIdentity: runtimeIdentity
        ))
    }

    static func verifiedRouteAuthorizes(
        _ binding: CodexReloadBinding,
        verifiedRoute: VerifiedRoute
    ) -> Bool {
        let route = verifiedRoute.route
        return binding.processIdentity.ownerUID == UInt32(getuid())
            && route.runtimePath == binding.processIdentity.executablePath
            && route.runtimePath == binding.kernelExecutableIdentity.canonicalPath
            && verifiedRoute.runtimeIdentity.device
                == binding.kernelExecutableIdentity.device
            && verifiedRoute.runtimeIdentity.inode
                == binding.kernelExecutableIdentity.inode
    }

    static func retainedRuntimeAuthorizes(
        _ binding: CodexReloadBinding,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard binding.runtimeKind == .localInteractiveCLI,
              binding.processIdentity.ownerUID == UInt32(getuid()) else {
            return false
        }

        let preparedRoot = CodexDesktopPathSecurity.lexicallyStandardized(
            homeDirectory.appendingPathComponent(
                ".local/share/codexswitch/prepared-codex",
                isDirectory: true
            )
        )
        let runtimeURL = CodexDesktopPathSecurity.lexicallyStandardized(
            URL(fileURLWithPath: binding.kernelExecutableIdentity.canonicalPath)
        )
        let generationRoot = runtimeURL.deletingLastPathComponent()
        let versionRoot = generationRoot.deletingLastPathComponent()
        guard runtimeURL.lastPathComponent == "codex",
              versionRoot.deletingLastPathComponent().path == preparedRoot.path,
              !versionRoot.lastPathComponent.isEmpty,
              !generationRoot.lastPathComponent.isEmpty,
              binding.processIdentity.executablePath == runtimeURL.path,
              CodexDesktopPathSecurity.containsNoSymbolicLinkComponents(
                  generationRoot
              ),
              let manifest = readManifest(
                  at: generationRoot.appendingPathComponent("manifest.json")
              ),
              manifest.format == artifactFormat,
              manifest.architecture == "arm64",
              manifest.upstreamCodexVersion == versionRoot.lastPathComponent,
              manifest.buildEpoch > 0,
              isLowercaseHex(manifest.codexSwitchGitSha, count: 40),
              isLowercaseHex(manifest.sourcePatchSha256, count: 64) else {
            return false
        }

        let filesByName = Dictionary(grouping: manifest.files, by: \.name)
        let expectedNames = Set(["codex", "codex-code-mode-host", "codexswitch-cli"])
        guard manifest.files.count == expectedNames.count,
              Set(filesByName.keys) == expectedNames,
              filesByName.values.allSatisfy({ $0.count == 1 }),
              let runtime = filesByName["codex"]?.first,
              let helper = filesByName["codex-code-mode-host"]?.first,
              let controlPlane = filesByName["codexswitch-cli"]?.first,
              manifest.files.allSatisfy({
                  $0.bytes > 0 && isLowercaseHex($0.sha256, count: 64)
              }),
              let runtimeIdentity = verifiedReadOnlyFile(
                  at: runtimeURL.path,
                  expectedSHA256: runtime.sha256,
                  expectedBytes: runtime.bytes,
                  maximumBytes: maximumRuntimeBytes
              ),
              runtimeIdentity.device == binding.kernelExecutableIdentity.device,
              runtimeIdentity.inode == binding.kernelExecutableIdentity.inode,
              verifiedReadOnlyFile(
                  at: generationRoot
                      .appendingPathComponent("codex-code-mode-host").path,
                  expectedSHA256: helper.sha256,
                  expectedBytes: helper.bytes,
                  maximumBytes: maximumHelperBytes
              ) != nil,
              verifiedReadOnlyFile(
                  at: generationRoot.appendingPathComponent("codexswitch-cli").path,
                  expectedSHA256: controlPlane.sha256,
                  expectedBytes: controlPlane.bytes,
                  maximumBytes: maximumControlPlaneBytes
              ) != nil else {
            return false
        }
        return true
    }

    private static func verifiedReadOnlyFile(
        at path: String,
        expectedSHA256: String,
        expectedBytes: Int64? = nil,
        maximumBytes: Int64
    ) -> DesktopInstallPathIdentity? {
        guard var metadata = fileMetadata(at: path),
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o222 == 0,
              let file = try? DesktopPinnedRegularFile(
                  url: URL(fileURLWithPath: path),
                  maximumBytes: maximumBytes
              ),
              file.byteCount > 0,
              expectedBytes.map({ $0 == file.byteCount }) ?? true,
              let digest = try? file.sha256(isCancelled: { false }),
              digest == expectedSHA256,
              file.verifyPathIdentity() else {
            return nil
        }
        metadata = stat()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o222 == 0 else {
            return nil
        }
        return file.identity
    }

    private static func readManifest(at url: URL) -> ArtifactManifest? {
        guard var metadata = fileMetadata(at: url.path),
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o222 == 0,
              let file = try? DesktopPinnedRegularFile(
                  url: url,
                  maximumBytes: maximumManifestBytes
              ),
              file.byteCount > 0,
              file.byteCount <= Int64(Int.max),
              let bytes = try? file.read(
                  offset: 0,
                  count: Int(file.byteCount)
              ),
              file.verifyPathIdentity(),
              let manifest = try? JSONDecoder().decode(
                  ArtifactManifest.self,
                  from: bytes
              ) else {
            return nil
        }
        metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o222 == 0 else {
            return nil
        }
        return manifest
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count
            && value.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value)
                    || (97...102).contains(scalar.value)
            }
    }

    private static func fileMetadata(at path: String) -> stat? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return metadata
    }
}
