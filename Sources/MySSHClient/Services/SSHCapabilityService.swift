import Darwin
import Foundation
import os

enum SSHCapabilityQueryResult: Equatable, Sendable {
    case available(SSHClientCapabilities)
    case unavailable

    var capabilities: SSHClientCapabilities? {
        if case .available(let value) = self { return value }
        return nil
    }
}

/// All subprocess work and cache access is confined to this private serial queue.
/// The fixed queries do not evaluate the user's SSH configuration or connect.
final class SSHCapabilityService: Sendable {
    static let shared = SSHCapabilityService()
    private let queue = DispatchQueue(label: "MyTerm.ssh-capabilities", qos: .userInitiated)
    private struct Cache { var identity: String?; var result: SSHCapabilityQueryResult? }
    private let cache = OSAllocatedUnfairLock(initialState: Cache())

    func query(forceRefresh: Bool = false) async -> SSHCapabilityQueryResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.queryOnQueue(forceRefresh: forceRefresh))
            }
        }
    }

    /// Existing SFTP and platform-probe transports run on background queues.
    /// Refuse a blocking query on the main thread instead of freezing the UI.
    func queryFromWorker() -> SSHCapabilityQueryResult {
        guard !Thread.isMainThread else { return .unavailable }
        return queue.sync { queryOnQueue(forceRefresh: false) }
    }

    private func queryOnQueue(forceRefresh: Bool) -> SSHCapabilityQueryResult {
        guard let identity = Self.executableIdentity() else { return .unavailable }
        if !forceRefresh, let cached = cache.withLock({ $0.identity == identity ? $0.result : nil }) { return cached }
        let result: SSHCapabilityQueryResult
        if let version = Self.capture(arguments: ["-V"]),
           let algorithms = Self.capture(arguments: ["-Q", "kex"]),
           Self.executableIdentity() == identity {
            result = Self.parse(version: version.stdout + version.stderr, algorithms: algorithms.stdout)
        } else {
            result = .unavailable
        }
        cache.withLock { $0.identity = identity; $0.result = result }
        return result
    }

    private static func executableIdentity() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: "/usr/bin/ssh"),
              let inode = attrs[.systemFileNumber] as? NSNumber,
              let device = attrs[.systemNumber] as? NSNumber,
              let size = attrs[.size] as? NSNumber,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return "\(device):\(inode):\(size):\(modified.timeIntervalSince1970)"
    }

    static func parse(version: Data, algorithms: Data) -> SSHCapabilityQueryResult {
        guard version.count <= 32768, algorithms.count <= 32768,
              let versionText = String(data: version, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              versionText.hasPrefix("OpenSSH_"), versionText.count <= 512,
              !versionText.contains(where: { $0.isNewline }),
              let text = String(data: algorithms, encoding: .utf8) else { return .unavailable }
        let names = text.split(whereSeparator: \.isNewline).map(String.init)
        let characters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._-")
        guard !names.isEmpty, names.count <= 256,
              names.allSatisfy({ !$0.isEmpty && $0.count <= 256 && $0.rangeOfCharacter(from: characters.inverted) == nil }) else {
            return .unavailable
        }
        return .available(SSHClientCapabilities(version: versionText, keyExchangeAlgorithms: Set(names)))
    }

    private struct CapturedOutput { var stdout = Data(); var stderr = Data() }

    private static func capture(arguments: [String]) -> CapturedOutput? {
        capture(executable: "/usr/bin/ssh", arguments: arguments, timeout: 2, limit: 32768)
    }

    private static func capture(executable: String, arguments: [String], timeout: TimeInterval, limit: Int) -> CapturedOutput? {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = error.fileHandleForReading.fileDescriptor
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? error.fileHandleForReading.close()
            try? error.fileHandleForWriting.close()
        }
        guard fcntl(outFD, F_SETFL, O_NONBLOCK) != -1,
              fcntl(errFD, F_SETFL, O_NONBLOCK) != -1 else { return nil }
        do { try process.run() } catch { return nil }
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        defer {
            if process.isRunning {
                // Only the exact child created above; never a name-based kill.
                kill(process.processIdentifier, SIGKILL)
                let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < cleanupDeadline { usleep(5000) }
            }
        }
        var result = CapturedOutput()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = [UInt8](repeating: 0, count: 4096)
        func readAvailable(_ fd: Int32, into data: inout Data) -> Bool {
            // Bounded per pass so a noisy child cannot starve the deadline.
            for _ in 0..<16 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= limit else { return false }
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return true }
                else if errno != EINTR { return false }
            }
            return true
        }
        while true {
            guard readAvailable(outFD, into: &result.stdout), readAvailable(errFD, into: &result.stderr),
                  result.stdout.count + result.stderr.count <= limit else { return nil }
            if !process.isRunning {
                guard readAvailable(outFD, into: &result.stdout), readAvailable(errFD, into: &result.stderr),
                      result.stdout.count + result.stderr.count <= limit,
                      process.terminationStatus == 0 else { return nil }
                return result
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            usleep(5000)
        }
    }

#if MYTERM_SELF_TESTS
    static func captureForTesting(executable: String, arguments: [String], timeout: TimeInterval = 0.1, limit: Int = 1024) -> Bool {
        capture(executable: executable, arguments: arguments, timeout: timeout, limit: limit) != nil
    }
#endif
}
