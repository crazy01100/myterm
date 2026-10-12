import CryptoKit
import Darwin
import Foundation

struct SFTPEditSnapshot {
    let url: URL
    let digest: String
    let size: UInt64

    func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

/// All observer state belongs to `queue`; stop synchronously invalidates pending
/// work. Callbacks deliver immutable, separately owned snapshots, never the live
/// editor file. Both vnodes are needed: directories do not report in-place writes.
final class SFTPEditFileMonitor {
    private let queue = DispatchQueue(label: "MyTerm.SFTP.edit-monitor", qos: .utility)
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var epoch = 0
    private var stopped = false
    private let cancellation = SFTPTransferCancellation()
    private var lastDigest: String
    private var initialScan = true
    private let file: URL
    private let snapshotRoot: URL
    private let changed: (Result<SFTPEditSnapshot, Error>) -> Void

    init(file: URL, snapshotRoot: URL, baseline: String,
         changed: @escaping (Result<SFTPEditSnapshot, Error>) -> Void) throws {
        self.file = file; self.snapshotRoot = snapshotRoot
        self.lastDigest = baseline; self.changed = changed
        let fd = open(file.deletingLastPathComponent().path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SFTPEditError.unstableFile }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .rename, .delete], queue: queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in self?.event() }
        directorySource = source
        source.resume()
        queue.sync { bindFile(); event() }
    }

    func stop() {
        cancellation.cancel()
        queue.sync {
            stopped = true; epoch += 1
            directorySource?.cancel(); directorySource = nil
            fileSource?.cancel(); fileSource = nil
        }
    }

    func rescan() { queue.async { [weak self] in self?.event() } }

    private func bindFile() {
        fileSource?.cancel(); fileSource = nil
        let fd = open(file.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete], queue: queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in self?.event() }
        fileSource = source; source.resume()
    }

    private func event() {
        guard !stopped else { return }
        epoch += 1; bindFile()
        let version = epoch
        queue.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            self?.scan(version: version, attempt: 0)
        }
    }

    private func scan(version: Int, attempt: Int) {
        guard !stopped, version == epoch else { return }
        do {
            let first = try Self.capture(file, under: snapshotRoot, cancellation: cancellation)
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                defer { first.remove() }
                guard let self, !stopped, version == epoch else { return }
                do {
                    let stable = try Self.capture(file, under: snapshotRoot, cancellation: cancellation)
                    guard stable.digest == first.digest else {
                        stable.remove(); retry(version: version, attempt: attempt); return
                    }
                    if stable.digest == lastDigest && !initialScan { stable.remove(); return }
                    initialScan = false
                    lastDigest = stable.digest
                    changed(.success(stable))
                } catch { retry(version: version, attempt: attempt) }
            }
        } catch { retry(version: version, attempt: attempt) }
    }

    private func retry(version: Int, attempt: Int) {
        guard !stopped, version == epoch else { return }
        if attempt >= 5 { changed(.failure(SFTPEditError.unstableFile)); return }
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            self?.scan(version: version, attempt: attempt + 1)
        }
    }

    static func privateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
            throw SFTPEditError.unstableFile
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func capture(_ file: URL, under root: URL, cancellation: SFTPTransferCancellation? = nil) throws -> SFTPEditSnapshot {
        try cancellation?.check()
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw SFTPEditError.unstableFile }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == file.deletingLastPathComponent().standardizedFileURL.path else {
            throw SFTPEditError.unstableFile
        }
        // An editor's atomic replacement may reset mode; keep the private draft
        // private without copying that mode back to the remote file.
        if before.st_mode & 0o777 != 0o600, fchmod(fd, 0o600) != 0 { throw SFTPEditError.unstableFile }
        guard fstat(fd, &before) == 0 else { throw SFTPEditError.unstableFile }
        try privateDirectory(root)
        let container = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try privateDirectory(container)
        let destination = container.appendingPathComponent(file.lastPathComponent)
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: container) } }
        let outputFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var hash = SHA256(), size: UInt64 = 0
        while let bytes = try input.read(upToCount: 64 * 1024), !bytes.isEmpty {
            try cancellation?.check()
            hash.update(data: bytes); size += UInt64(bytes.count)
            try output.write(contentsOf: bytes)
        }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, lstat(file.path, &path) == 0,
              before.st_ino == path.st_ino, before.st_dev == path.st_dev,
              before.st_size == after.st_size, before.st_size == size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw SFTPEditError.unstableFile }
        try output.synchronize()
        keep = true
        return SFTPEditSnapshot(url: destination, digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), size: size)
    }

    deinit { directorySource?.cancel(); fileSource?.cancel() }
}
