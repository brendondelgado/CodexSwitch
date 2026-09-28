import Darwin
import Foundation

// Serializes expensive marker scans and retains only results for unchanged files.
final class RuntimeMarkerScanCache: @unchecked Sendable {
    private struct Metadata: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let mode: mode_t
        let owner: uid_t
        let group: gid_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            mode = value.st_mode
            owner = value.st_uid
            group = value.st_gid
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private struct Key: Hashable {
        let path: String
        let marker: String
        let chunkSize: Int
    }

    private struct Entry {
        let metadata: Metadata
        let result: Bool
    }

    private let lock = NSLock()
    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var insertionOrder: [Key] = []

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    func result(
        at path: String,
        marker: String = "",
        chunkSize: Int,
        scan: (FileHandle) -> Bool?
    ) -> Bool {
        guard chunkSize > 0 else { return false }
        lock.lock()
        defer { lock.unlock() }

        let key = Key(path: path, marker: marker, chunkSize: chunkSize)
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            remove(key)
            return false
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let before = metadata(descriptor), matchesPath(path, before) else {
            remove(key)
            return false
        }
        if let entry = entries[key], entry.metadata == before {
            return entry.result
        }
        remove(key)
        guard let result = scan(handle),
              metadata(descriptor) == before,
              matchesPath(path, before) else {
            return false
        }
        if entries.count >= capacity, let oldest = insertionOrder.first {
            remove(oldest)
        }
        entries[key] = Entry(metadata: before, result: result)
        insertionOrder.append(key)
        return result
    }

    private func remove(_ key: Key) {
        entries.removeValue(forKey: key)
        insertionOrder.removeAll { $0 == key }
    }

    private func metadata(_ descriptor: Int32) -> Metadata? {
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              value.st_mode & S_IFMT == S_IFREG else { return nil }
        return Metadata(value)
    }

    private func matchesPath(_ path: String, _ expected: Metadata) -> Bool {
        var value = stat()
        return lstat(path, &value) == 0
            && value.st_mode & S_IFMT == S_IFREG
            && Metadata(value) == expected
    }
}
