import CryptoKit
import Darwin
import Foundation

/// Disk work runs off the main actor. No symlinks are followed, including when
/// removing internal snapshots. The manifest is removed last so interrupted
/// cleanup remains visible and retryable instead of becoming an orphan draft.
enum SFTPEditCacheCleanup {
    struct Fingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
    }

    static func verify(file: URL, baseline: SFTPEditRevision, cancellation: SFTPTransferCancellation) throws -> Fingerprint {
        try cancellation.check()
        guard file.resolvingSymlinksInPath().standardizedFileURL.path == file.standardizedFileURL.path else {
            throw SFTPEditError.unstableFile
        }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw SFTPEditError.unstableFile }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat(), after = stat(), path = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size == baseline.size else { throw SFTPEditError.unstableFile }
        var hash = SHA256(), size: UInt64 = 0
        while let bytes = try input.read(upToCount: 64 * 1024), !bytes.isEmpty {
            try cancellation.check()
            hash.update(data: bytes); size += UInt64(bytes.count)
        }
        guard fstat(fd, &after) == 0, lstat(file.path, &path) == 0,
              Fingerprint(before) == Fingerprint(after), Fingerprint(before) == Fingerprint(path),
              size == baseline.size,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == baseline.digest else {
            throw SFTPEditError.unstableFile
        }
        try cancellation.check()
        return Fingerprint(after)
    }

    static func stable(file: URL, baseline: SFTPEditRevision, cancellation: SFTPTransferCancellation) async throws -> Fingerprint {
        let first = try verify(file: file, baseline: baseline, cancellation: cancellation)
        try await Task.sleep(for: .milliseconds(250))
        let second = try verify(file: file, baseline: baseline, cancellation: cancellation)
        guard first == second else { throw SFTPEditError.unstableFile }
        return second
    }

    private static func names(_ fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw CocoaError(.fileReadUnknown) }
        guard let directory = fdopendir(copy) else { close(copy); throw CocoaError(.fileReadUnknown) }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw CocoaError(.fileReadUnknown) }
        return result
    }

    private static func removeTree(_ name: String, parent: Int32, cancellation: SFTPTransferCancellation, depth: Int = 0) throws {
        try cancellation.check()
        guard depth < 8 else { throw SFTPEditError.unstableFile }
        var attributes = stat()
        guard fstatat(parent, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw CocoaError(.fileReadUnknown)
        }
        if attributes.st_mode & S_IFMT == S_IFDIR {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw SFTPEditError.unstableFile }
            defer { close(child) }
            for item in try names(child) { try removeTree(item, parent: child, cancellation: cancellation, depth: depth + 1) }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else {
            guard attributes.st_mode & S_IFMT == S_IFREG else { throw SFTPEditError.unstableFile }
            guard unlinkat(parent, name, 0) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// Only after a durable cleanupStarted marker and a second content check.
    /// A missing content file is allowed solely when resuming that journal.
    static func remove(root: URL, id: UUID, name: String, fingerprint: Fingerprint?,
                       cancellation: SFTPTransferCancellation) throws {
        try cancellation.check()
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.standardizedFileURL.path,
              name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw SFTPEditError.unstableFile }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw SFTPEditError.unstableFile }
        defer { close(rootFD) }
        let job = openat(rootFD, id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard job >= 0 else { throw SFTPEditError.unstableFile }
        defer { close(job) }
        let items = try names(job)
        guard Set(items).isSubset(of: ["work.json", "content", "snapshots"]) else { throw SFTPEditError.unstableFile }
        if items.contains("content") {
            let content = openat(job, "content", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard content >= 0 else { throw SFTPEditError.unstableFile }
            defer { close(content) }
            let files = try names(content)
            guard files.isEmpty || files == [name] else { throw SFTPEditError.unstableFile }
            if !files.isEmpty {
                var attributes = stat()
                guard let fingerprint, fstatat(content, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0,
                      attributes.st_mode & S_IFMT == S_IFREG, Fingerprint(attributes) == fingerprint else {
                    throw SFTPEditError.unstableFile
                }
                try cancellation.check()
                guard unlinkat(content, name, 0) == 0 else { throw CocoaError(.fileWriteUnknown) }
            } else if fingerprint != nil { throw SFTPEditError.unstableFile }
            guard unlinkat(job, "content", AT_REMOVEDIR) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else if fingerprint != nil { throw SFTPEditError.unstableFile }
        try removeTree("snapshots", parent: job, cancellation: cancellation)
        // Never lose the journal while any unexpected file remains.
        guard try names(job) == ["work.json"] else { throw SFTPEditError.unstableFile }
        try cancellation.check()
        guard unlinkat(job, "work.json", 0) == 0 else { throw CocoaError(.fileWriteUnknown) }
        // A crash here can leave only an empty directory, never user content.
        _ = unlinkat(rootFD, id.uuidString, AT_REMOVEDIR)
    }
}
