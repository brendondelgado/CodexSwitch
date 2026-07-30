import Darwin
import Foundation

enum CodexSwitchInstanceRole: Equatable, Sendable {
    case unresolved
    case primary
    case duplicate

    static func resolve(lockAcquired: Bool) -> Self {
        lockAcquired ? .primary : .duplicate
    }

    var mayStartServices: Bool {
        self == .primary
    }

    var requiresTerminationPersistence: Bool {
        self == .primary
    }
}

final class SingleInstanceLock {
    private let path: String
    private var fd: Int32 = -1

    init(path: String = SingleInstanceLock.defaultPath) {
        self.path = path
    }

    deinit {
        release()
    }

    static var defaultPath: String {
        let dir = NSString("~/.codexswitch").expandingTildeInPath
        return "\(dir)/codexswitch-app.lock"
    }

    @discardableResult
    func acquire(pid: Int32 = getpid()) -> Bool {
        if fd >= 0 {
            return true
        }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let opened = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard opened >= 0 else {
            return false
        }

        var metadata = stat()
        guard fstat(opened, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG,
              fchmod(opened, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(opened)
            return false
        }

        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(opened)
            return false
        }

        fd = opened
        _ = ftruncate(fd, 0)
        let pidLine = "\(pid)\n"
        if let data = pidLine.data(using: .utf8) {
            data.withUnsafeBytes { buffer in
                if let baseAddress = buffer.baseAddress {
                    _ = Darwin.write(fd, baseAddress, buffer.count)
                }
            }
        }
        _ = fsync(fd)
        return true
    }

    func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
        fd = -1
    }
}
