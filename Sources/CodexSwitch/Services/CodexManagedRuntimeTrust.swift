import Darwin
import Foundation

enum CodexManagedRuntimeTrust {
    private static let maximumRuntimeBytes: Int64 = 512 * 1024 * 1024
    private static let maximumHelperBytes: Int64 = 128 * 1024 * 1024

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

    private static func verifiedReadOnlyFile(
        at path: String,
        expectedSHA256: String,
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

    private static func fileMetadata(at path: String) -> stat? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return metadata
    }
}
