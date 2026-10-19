import Darwin
import Foundation
import os

/// Private named pipe for OpenSSH -E. Raw bytes never enter a regular log file.
/// Reads and state changes share one lock; the read source only captures weak self.
final class SSHDiagnosticStream: Sendable {
    struct Snapshot {
        var bytes: Data
        var protection: SSHNegotiatedProtection
        var failureMessage: String
    }
    private struct State {
        var source: DispatchSourceRead?
        var anchor: Int32
        var stopped = false
        var retainBytes = true
        var bytes = Data()
        var protection = SSHProtectionParser()
        var diagnostic = SSHConnectionLogParser()
        var errorLines: [String] = []
        var failureSummary: String?
    }
    let url: URL
    private let fd: Int32
    private let state: OSAllocatedUnfairLock<State>
    private let requiresPostQuantum: Bool

    init(requiresPostQuantum: Bool = false) throws {
        self.requiresPostQuantum = requiresPostQuantum
        let url = try AppPaths.createSSHConnectionLog()
        self.url = url
        try FileManager.default.removeItem(at: url)
        guard mkfifo(url.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { AppPaths.removeSSHConnectionLog(url); throw POSIXError(.EIO) }
        let anchor = open(url.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard anchor >= 0 else { Darwin.close(descriptor); AppPaths.removeSSHConnectionLog(url); throw POSIXError(.EIO) }
        fd = descriptor
        state = OSAllocatedUnfairLock(initialState: State(anchor: anchor))
        let queue = DispatchQueue(label: "MyTerm.ssh-diagnostic-stream", qos: .utility)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(descriptor) }
        state.withLock { $0.source = source }
        source.resume()
    }

    private func drain() {
        state.withLock { state in
            guard !state.stopped else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<16 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    if state.anchor >= 0 { Darwin.close(state.anchor); state.anchor = -1 }
                    let chunk = Data(buffer.prefix(count))
                    state.protection.consume(chunk)
                    let parsed = state.diagnostic.consume(Array(chunk)[...])
                    if let failure = parsed.failure, requiresPostQuantum && failure == .keyExchangeAlgorithm {
                        state.failureSummary = failure.title(requiringPostQuantum: true) + "。" + failure.recoverySuggestion(requiringPostQuantum: true)
                    }
                    state.errorLines.append(contentsOf: parsed.technicalLines)
                    state.errorLines = Array(state.errorLines.suffix(12)).map { String($0.prefix(1024)) }
                    if state.retainBytes {
                        if state.bytes.count + count <= 65536 { state.bytes.append(chunk) }
                        else { state.bytes.removeAll(); state.protection.loseObservation() }
                    }
                } else if count == 0 {
                    state.protection.loseObservation()
                    state.source?.cancel()
                    state.stopped = true
                    break
                } else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                else if errno != EINTR {
                    state.protection.loseObservation()
                    state.source?.cancel()
                    state.stopped = true
                    break
                }
            }
        }
    }

    func snapshot() -> Snapshot {
        drain()
        return state.withLock {
            let result = Snapshot(bytes: $0.bytes, protection: $0.protection.value, failureMessage: $0.failureSummary ?? $0.errorLines.joined(separator: "\n"))
            $0.bytes.removeAll(keepingCapacity: false)
            return result
        }
    }

    func discardAuthenticationBytes() {
        state.withLock { $0.retainBytes = false; $0.bytes.removeAll(); $0.errorLines.removeAll() }
    }

    func close() {
        state.withLock {
            if $0.anchor >= 0 { Darwin.close($0.anchor); $0.anchor = -1 }
            $0.source?.cancel()
            $0.stopped = true
            $0.bytes.removeAll()
        }
        AppPaths.removeSSHConnectionLog(url)
    }
    deinit { close() }
}
