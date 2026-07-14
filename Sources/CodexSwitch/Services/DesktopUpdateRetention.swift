import Darwin
import Foundation

enum DesktopUpdateBoundedRetentionFS {
    static func entryNames(in root: URL, maximumEntries: Int) throws -> [String] {
        guard maximumEntries > 0 else { return [] }
        let rootDescriptor = open(
            root.standardizedFileURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            throw retentionError("Could not open desktop update root for bounded retention")
        }
        defer { _ = close(rootDescriptor) }

        let enumerationDescriptor = dup(rootDescriptor)
        guard enumerationDescriptor >= 0,
              let directory = fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { _ = close(enumerationDescriptor) }
            throw retentionError("Could not enumerate desktop update root")
        }
        defer { _ = closedir(directory) }

        var names: [String] = []
        names.reserveCapacity(min(maximumEntries, 256))
        while let entry = readdir(directory) {
            let name = entryName(entry)
            if name == "." || name == ".." { continue }
            guard isSimpleName(name) else {
                throw retentionError("Desktop update root contained an invalid entry name")
            }
            guard names.count < maximumEntries else {
                throw retentionError("Desktop update root exceeded its bounded scan budget")
            }
            names.append(name)
        }
        return names.sorted()
    }

    static func identity(of url: URL) -> DesktopInstallPathIdentity? {
        var info = stat()
        guard lstat(url.standardizedFileURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return identity(info)
    }

    static func removeTree(
        named name: String,
        from root: URL,
        expectedIdentity: DesktopInstallPathIdentity,
        maximumEntries: Int
    ) throws {
        guard isSimpleName(name), maximumEntries > 0 else {
            throw retentionError("Retention removal request was invalid")
        }
        let rootDescriptor = open(
            root.standardizedFileURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            throw retentionError("Could not retain desktop update root for removal")
        }
        defer { _ = close(rootDescriptor) }

        var current = stat()
        guard fstatat(rootDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              identity(current) == expectedIdentity else {
            throw retentionError("Retention candidate identity changed before removal")
        }
        var remaining = maximumEntries
        try removeEntry(named: name, parentDescriptor: rootDescriptor, remaining: &remaining)
        guard fsync(rootDescriptor) == 0 else {
            throw retentionError("Could not synchronize desktop update retention")
        }
    }

    private static func removeEntry(
        named name: String,
        parentDescriptor: Int32,
        remaining: inout Int
    ) throws {
        guard remaining > 0 else {
            throw retentionError("Retention removal exceeded its entry budget")
        }
        remaining -= 1

        var info = stat()
        guard fstatat(parentDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw retentionError("Could not inspect retention candidate")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            guard unlinkat(parentDescriptor, name, 0) == 0 else {
                throw retentionError("Could not remove retention file")
            }
            return
        }

        let childDescriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard childDescriptor >= 0 else {
            throw retentionError("Could not retain retention directory")
        }
        defer { _ = close(childDescriptor) }

        let enumerationDescriptor = dup(childDescriptor)
        guard enumerationDescriptor >= 0,
              let directory = fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 { _ = close(enumerationDescriptor) }
            throw retentionError("Could not enumerate retention directory")
        }
        defer { _ = closedir(directory) }

        while let entry = readdir(directory) {
            let childName = entryName(entry)
            if childName == "." || childName == ".." { continue }
            guard isSimpleName(childName) else {
                throw retentionError("Retention directory contained an invalid entry name")
            }
            try removeEntry(
                named: childName,
                parentDescriptor: childDescriptor,
                remaining: &remaining
            )
        }
        guard unlinkat(parentDescriptor, name, AT_REMOVEDIR) == 0 else {
            throw retentionError("Could not remove retention directory")
        }
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        var tuple = entry.pointee.d_name
        let tupleSize = MemoryLayout.size(ofValue: tuple)
        return withUnsafePointer(to: &tuple) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: tupleSize
            ) { String(cString: $0) }
        }
    }

    private static func isSimpleName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func identity(_ info: stat) -> DesktopInstallPathIdentity {
        DesktopInstallPathIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }

    private static func retentionError(_ message: String) -> NSError {
        NSError(
            domain: "DesktopUpdateBoundedRetentionFS",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
