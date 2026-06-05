import Darwin
import Foundation

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

        let opened = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard opened >= 0 else {
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
        return true
    }

    func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
        fd = -1
    }
}
