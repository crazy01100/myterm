import Darwin
import Foundation

enum SFTPConnectionError: LocalizedError {
    case missingSavedPassword
    case unsupportedPassword
    case failedToStart(String)
    case connectionClosed(String)

    var errorDescription: String? {
        switch self {
        case .missingSavedPassword:
            "這台主機尚未在 Keychain 儲存密碼。請先編輯主機並儲存密碼，再使用 SFTP。"
        case .unsupportedPassword:
            "目前無法將包含換行或過長的密碼安全交給 OpenSSH。"
        case .failedToStart(let message):
            message.isEmpty ? "無法啟動 SFTP 連線。" : "無法啟動 SFTP 連線：\(message)"
        case .connectionClosed(let message):
            message.isEmpty ? "SFTP 連線已關閉。" : "SFTP 連線已關閉：\(message)"
        }
    }
}

enum SFTPFileOperationError: LocalizedError {
    case destinationExists(String)
    case unsafeName(String)
    case symbolicLinkTransferUnsupported(String)
    case notARegularFile(String)

    var errorDescription: String? {
        switch self {
        case .destinationExists(let name): "目標位置已經有「\(name)」，為避免覆蓋資料，操作已停止。"
        case .unsafeName(let name): "遠端伺服器傳回不安全的檔名「\(name)」，操作已停止。"
        case .symbolicLinkTransferUnsupported(let name): "目前不會自動跟隨符號連結「\(name)」，以免意外傳輸連結範圍外的資料。"
        case .notARegularFile(let name): "「\(name)」不是可傳輸的一般檔案。"
        }
    }
}

private final class SFTPStderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maximumSize = 128 * 1_024

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = maximumSize - data.count
        if remaining > 0 { data.append(newData.prefix(remaining)) }
    }

    var message: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Supplies a Keychain password to OpenSSH through a user-only FIFO. The secret
/// is never placed in process arguments, environment variables, or a file.
private final class SFTPPasswordPipe {
    let askPassURL: URL
    let fifoURL: URL
    private let directoryURL: URL
    private var fileDescriptor: Int32 = -1

    init(password: String) throws {
        guard !password.contains("\n"), !password.contains("\r"), password.utf8.count <= 8_192 else {
            throw SFTPConnectionError.unsupportedPassword
        }
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "MyTerm-SFTP-\(UUID().uuidString)", directoryHint: .isDirectory)
        askPassURL = directoryURL.appending(path: "askpass")
        fifoURL = directoryURL.appending(path: "credential")

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard mkfifo(fifoURL.path, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let escapedFIFO = fifoURL.path.replacingOccurrences(of: "'", with: "'\\''")
            let script = """
            #!/bin/zsh
            IFS= read -r reply < '\(escapedFIFO)'
            print -r -- "$reply"
            """
            try Data(script.utf8).write(to: askPassURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askPassURL.path)

            fileDescriptor = Darwin.open(fifoURL.path, O_RDWR | O_NONBLOCK)
            guard fileDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let repeated = String(repeating: "\(password)\n", count: 4)
            let bytes = Array(repeated.utf8)
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(fileDescriptor, buffer.baseAddress, buffer.count)
            }
            guard written == bytes.count else {
                throw POSIXError(.EIO)
            }
        } catch {
            cleanup()
            throw error
        }
    }

    func cleanup() {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    deinit { cleanup() }
}

private final class SFTPProcessSession {
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let stderr = SFTPStderrCollector()
    private let stateLock = NSLock()
    private var isClosed = false

    init(
        arguments: [String],
        environment: [String: String],
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")
    ) throws {
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        errorPipe.fileHandleForReading.readabilityHandler = { [stderr] handle in
            stderr.append(handle.availableData)
        }
        do {
            try process.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw SFTPConnectionError.failedToStart(error.localizedDescription)
        }
    }

    func write(_ data: Data) throws {
        stateLock.lock()
        let canWrite = !isClosed
        stateLock.unlock()
        guard canWrite else { throw SFTPConnectionError.connectionClosed(stderr.message) }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw SFTPConnectionError.connectionClosed(stderr.message.isEmpty ? error.localizedDescription : stderr.message)
        }
    }

    func readPacket() throws -> Data {
        let header = try readExactly(4)
        let length = header.reduce(Int(0)) { ($0 << 8) | Int($1) }
        guard length > 0 else { throw SFTPProtocolError.malformedPacket }
        guard length <= SFTPProtocolCodec.maximumPacketSize else {
            throw SFTPProtocolError.packetTooLarge(length)
        }
        return try readExactly(length)
    }

    func close() {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        isClosed = true
        stateLock.unlock()
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        try? outputPipe.fileHandleForReading.close()
        if process.isRunning { process.terminate() }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let chunk: Data
            do {
                chunk = try outputPipe.fileHandleForReading.read(upToCount: count - result.count) ?? Data()
            } catch {
                throw SFTPConnectionError.connectionClosed(stderr.message.isEmpty ? error.localizedDescription : stderr.message)
            }
            guard !chunk.isEmpty else {
                throw SFTPConnectionError.connectionClosed(stderr.message)
            }
            result.append(chunk)
        }
        return result
    }

    deinit { close() }
}

final class SFTPClient: @unchecked Sendable {
    private let session: SFTPProcessSession
    private var nextRequestID: UInt32 = 1
    private let operationLock = NSLock()

    private init(session: SFTPProcessSession) {
        self.session = session
    }

    static func connect(to host: HostProfile, username: String) throws -> SFTPClient {
        var arguments = try SSHArgumentBuilder.arguments(for: host, usernameOverride: username)
        guard let destination = arguments.popLast() else {
            throw SFTPConnectionError.failedToStart("缺少 SSH 目的地。")
        }
        if host.authenticationMethod != .password {
            arguments += ["-o", "BatchMode=yes"]
        }
        arguments += ["-T", "-s", destination, "sftp"]

        var environment = SSHEnvironmentBuilder.environmentDictionary()
        var passwordPipe: SFTPPasswordPipe?
        if host.authenticationMethod == .password {
            guard let data = try KeychainStore.passwordData(for: host.id),
                  let password = String(data: data, encoding: .utf8) else {
                throw SFTPConnectionError.missingSavedPassword
            }
            let pipe = try SFTPPasswordPipe(password: password)
            passwordPipe = pipe
            environment["SSH_ASKPASS"] = pipe.askPassURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "myterm:0"
        }

        let processSession: SFTPProcessSession
        do {
            processSession = try SFTPProcessSession(arguments: arguments, environment: environment)
            try processSession.write(SFTPProtocolCodec.initializationPacket())
            try SFTPProtocolCodec.parseVersion(processSession.readPacket())
            passwordPipe?.cleanup()
        } catch {
            passwordPipe?.cleanup()
            throw error
        }
        return SFTPClient(session: processSession)
    }

#if MYTERM_SELF_TESTS
    static func connectForTesting(
        executableURL: URL,
        arguments: [String]
    ) throws -> SFTPClient {
        let session = try SFTPProcessSession(
            arguments: arguments,
            environment: SSHEnvironmentBuilder.environmentDictionary(),
            executableURL: executableURL
        )
        do {
            try session.write(SFTPProtocolCodec.initializationPacket())
            try SFTPProtocolCodec.parseVersion(session.readPacket())
            return SFTPClient(session: session)
        } catch {
            session.close()
            throw error
        }
    }
#endif

    func realPath(_ path: String) throws -> String {
        try synchronized { try realPathUnlocked(path) }
    }

    func listDirectory(_ path: String) throws -> [SFTPDirectoryEntry] {
        try synchronized { try listDirectoryUnlocked(path) }
    }

    func createDirectory(_ path: String, permissions: UInt32 = 0o755) throws {
        try synchronized {
            try requireMissingUnlocked(path)
            let response = try request(type: SFTPPacketType.makeDirectory) {
                $0.append(string: path)
                $0.appendPermissions(permissions)
            }
            try requireOK(response)
        }
    }

    func rename(from oldPath: String, to newPath: String) throws {
        try synchronized {
            try requireMissingUnlocked(newPath)
            let response = try request(type: SFTPPacketType.rename) {
                $0.append(string: oldPath)
                $0.append(string: newPath)
            }
            try requireOK(response)
        }
    }

    func setPermissions(_ permissions: UInt32, at path: String) throws {
        try synchronized {
            let response = try request(type: SFTPPacketType.setstat) {
                $0.append(string: path)
                $0.appendPermissions(permissions)
            }
            try requireOK(response)
        }
    }

    func removeRecursively(path: String, kind: SFTPFileKind) throws {
        try synchronized { try removeRecursivelyUnlocked(path: path, kind: kind) }
    }

    func existingItemNames(_ names: [String], in remoteDirectory: String) throws -> [String] {
        try synchronized {
            var result: [String] = []
            for name in names {
                try Self.validatePathComponent(name)
                if try attributesUnlocked(at: Self.appending(name, to: remoteDirectory)) != nil {
                    result.append(name)
                }
            }
            return result
        }
    }

    func uploadItem(
        at localURL: URL,
        to remoteDirectory: String,
        overwrite: Bool = false,
        progress: @escaping (UInt64, UInt64?) -> Void
    ) throws {
        try synchronized {
            var completed: UInt64 = 0
            let values = try localURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            let total = values.isDirectory == true ? nil : values.fileSize.map(UInt64.init)
            try uploadItemUnlocked(
                localURL,
                remotePath: Self.appending(localURL.lastPathComponent, to: remoteDirectory),
                overwriteExisting: overwrite,
                completed: &completed,
                total: total,
                progress: progress
            )
        }
    }

    func downloadItem(
        _ entry: SFTPDirectoryEntry,
        from remoteDirectory: String,
        to localDirectory: URL,
        overwrite: Bool = false,
        progress: @escaping (UInt64, UInt64?) -> Void
    ) throws {
        try synchronized {
            try Self.validatePathComponent(entry.name)
            var completed: UInt64 = 0
            let total = entry.isDirectory ? nil : entry.attributes.size
            let remotePath = Self.appending(entry.name, to: remoteDirectory)
            let localURL = localDirectory.appending(path: entry.name)
            if overwrite, FileManager.default.fileExists(atPath: localURL.path) {
                let replacementURL = localDirectory
                    .appending(path: ".myterm-replacement-\(UUID().uuidString)")
                do {
                    try downloadItemUnlocked(
                        entry,
                        remotePath: remotePath,
                        localURL: replacementURL,
                        completed: &completed,
                        total: total,
                        progress: progress
                    )
                    try Self.replaceLocalItem(at: localURL, with: replacementURL)
                } catch {
                    try? FileManager.default.removeItem(at: replacementURL)
                    throw error
                }
            } else {
                try downloadItemUnlocked(
                    entry,
                    remotePath: remotePath,
                    localURL: localURL,
                    completed: &completed,
                    total: total,
                    progress: progress
                )
            }
        }
    }

    func downloadTemporaryCopy(
        _ entry: SFTPDirectoryEntry,
        from remoteDirectory: String
    ) throws -> URL {
        guard !entry.isDirectory else { throw SFTPFileOperationError.notARegularFile(entry.name) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MyTerm SFTP Preview", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try downloadItem(entry, from: remoteDirectory, to: directory) { _, _ in }
            return directory.appending(path: entry.name)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func close() {
        session.close()
    }

    private func request(
        type: UInt8,
        body: (inout SFTPPacketWriter) -> Void
    ) throws -> (UInt8, SFTPPacketReader) {
        let requestID = nextRequestID
        nextRequestID &+= 1
        try session.write(SFTPProtocolCodec.requestPacket(type: type, requestID: requestID, body: body))
        return try SFTPProtocolCodec.responseReader(session.readPacket(), expectedRequestID: requestID)
    }

    private func realPathUnlocked(_ path: String) throws -> String {
        let response = try request(type: SFTPPacketType.realPath) { $0.append(string: path) }
        var (type, reader) = response
        if type == SFTPPacketType.status {
            _ = try SFTPProtocolCodec.parseStatus(&reader)
            throw SFTPProtocolError.unexpectedPacket(type)
        }
        guard type == SFTPPacketType.name else { throw SFTPProtocolError.unexpectedPacket(type) }
        guard let first = try SFTPProtocolCodec.parseNameEntries(&reader).first else {
            throw SFTPProtocolError.malformedPacket
        }
        return first.name
    }

    private func listDirectoryUnlocked(_ path: String) throws -> [SFTPDirectoryEntry] {
        let openResponse = try request(type: SFTPPacketType.openDirectory) { $0.append(string: path) }
        var (openType, openReader) = openResponse
        if openType == SFTPPacketType.status {
            _ = try SFTPProtocolCodec.parseStatus(&openReader)
            throw SFTPProtocolError.unexpectedPacket(openType)
        }
        guard openType == SFTPPacketType.handle else {
            throw SFTPProtocolError.unexpectedPacket(openType)
        }
        let handle = try openReader.readData()
        var entries: [SFTPDirectoryEntry] = []
        do {
            while true {
                let response = try request(type: SFTPPacketType.readDirectory) { $0.append(data: handle) }
                var (type, reader) = response
                if type == SFTPPacketType.status {
                    let shouldContinue = try SFTPProtocolCodec.parseStatus(&reader, allowEndOfFile: true)
                    if !shouldContinue { break }
                } else if type == SFTPPacketType.name {
                    entries.append(contentsOf: try SFTPProtocolCodec.parseNameEntries(&reader))
                } else {
                    throw SFTPProtocolError.unexpectedPacket(type)
                }
            }
            try closeHandle(handle)
        } catch {
            try? closeHandle(handle)
            throw error
        }
        return entries.filter { $0.name != "." && $0.name != ".." }
    }

    private func attributesUnlocked(at path: String) throws -> SFTPFileAttributes? {
        let response = try request(type: SFTPPacketType.lstat) { $0.append(string: path) }
        var (type, reader) = response
        if type == SFTPPacketType.attributes { return try reader.readAttributes() }
        guard type == SFTPPacketType.status else { throw SFTPProtocolError.unexpectedPacket(type) }
        let code = try reader.readUInt32()
        let message = reader.remainingCount > 0 ? (try? reader.readString()) ?? "" : ""
        if code == 2 { return nil }
        throw SFTPProtocolError.serverStatus(code: code, message: message)
    }

    private func requireMissingUnlocked(_ path: String) throws {
        if try attributesUnlocked(at: path) != nil {
            throw SFTPFileOperationError.destinationExists((path as NSString).lastPathComponent)
        }
    }

    private func requireOK(_ response: (UInt8, SFTPPacketReader)) throws {
        var (type, reader) = response
        guard type == SFTPPacketType.status else { throw SFTPProtocolError.unexpectedPacket(type) }
        _ = try SFTPProtocolCodec.parseStatus(&reader)
    }

    private func openFileUnlocked(path: String, flags: UInt32, permissions: UInt32 = 0o644) throws -> Data {
        let response = try request(type: SFTPPacketType.open) {
            $0.append(string: path)
            $0.append(flags)
            $0.appendPermissions(permissions)
        }
        var (type, reader) = response
        if type == SFTPPacketType.status {
            _ = try SFTPProtocolCodec.parseStatus(&reader)
            throw SFTPProtocolError.unexpectedPacket(type)
        }
        guard type == SFTPPacketType.handle else { throw SFTPProtocolError.unexpectedPacket(type) }
        return try reader.readData()
    }

    private func readFileUnlocked(handle: Data, offset: UInt64, length: UInt32) throws -> Data? {
        let response = try request(type: SFTPPacketType.read) {
            $0.append(data: handle)
            $0.append(offset)
            $0.append(length)
        }
        var (type, reader) = response
        if type == SFTPPacketType.data {
            let data = try SFTPProtocolCodec.parseData(&reader)
            guard !data.isEmpty else { throw SFTPProtocolError.malformedPacket }
            return data
        }
        guard type == SFTPPacketType.status else { throw SFTPProtocolError.unexpectedPacket(type) }
        let shouldContinue = try SFTPProtocolCodec.parseStatus(&reader, allowEndOfFile: true)
        return shouldContinue ? Data() : nil
    }

    private func writeFileUnlocked(handle: Data, offset: UInt64, data: Data) throws {
        let response = try request(type: SFTPPacketType.write) {
            $0.append(data: handle)
            $0.append(offset)
            $0.append(data: data)
        }
        try requireOK(response)
    }

    private func uploadItemUnlocked(
        _ localURL: URL,
        remotePath: String,
        overwriteExisting: Bool,
        completed: inout UInt64,
        total: UInt64?,
        progress: (UInt64, UInt64?) -> Void
    ) throws {
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true {
            throw SFTPFileOperationError.symbolicLinkTransferUnsupported(localURL.lastPathComponent)
        }
        if overwriteExisting, let existing = try attributesUnlocked(at: remotePath) {
            try removeRecursivelyUnlocked(path: remotePath, kind: existing.kind)
        }
        if values.isDirectory == true {
            try requireMissingUnlocked(remotePath)
            let response = try request(type: SFTPPacketType.makeDirectory) {
                $0.append(string: remotePath)
                $0.appendPermissions(0o755)
            }
            try requireOK(response)
            do {
                let children = try FileManager.default.contentsOfDirectory(
                    at: localURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: []
                )
                for child in children {
                    try uploadItemUnlocked(
                        child,
                        remotePath: Self.appending(child.lastPathComponent, to: remotePath),
                        overwriteExisting: false,
                        completed: &completed,
                        total: total,
                        progress: progress
                    )
                }
            } catch {
                try? removeRecursivelyUnlocked(path: remotePath, kind: .directory)
                throw error
            }
            return
        }
        guard values.fileSize != nil else {
            throw SFTPFileOperationError.notARegularFile(localURL.lastPathComponent)
        }
        try requireMissingUnlocked(remotePath)
        let localHandle = try FileHandle(forReadingFrom: localURL)
        var handle: Data?
        var offset: UInt64 = 0
        do {
            let openedHandle = try openFileUnlocked(path: remotePath, flags: 0x0000_002A)
            handle = openedHandle
            while true {
                let chunk = try localHandle.read(upToCount: 64 * 1_024) ?? Data()
                if chunk.isEmpty { break }
                try writeFileUnlocked(handle: openedHandle, offset: offset, data: chunk)
                let (nextOffset, overflow) = offset.addingReportingOverflow(UInt64(chunk.count))
                guard !overflow else { throw SFTPProtocolError.malformedPacket }
                offset = nextOffset
                completed &+= UInt64(chunk.count)
                progress(completed, total)
            }
            try closeHandle(openedHandle)
            handle = nil
            try localHandle.close()
        } catch {
            try? localHandle.close()
            if let handle {
                try? closeHandle(handle)
                try? removeFileUnlocked(remotePath)
            }
            throw error
        }
    }

    private func downloadItemUnlocked(
        _ entry: SFTPDirectoryEntry,
        remotePath: String,
        localURL: URL,
        completed: inout UInt64,
        total: UInt64?,
        progress: (UInt64, UInt64?) -> Void
    ) throws {
        try Self.validatePathComponent(entry.name)
        guard !FileManager.default.fileExists(atPath: localURL.path) else {
            throw SFTPFileOperationError.destinationExists(entry.name)
        }
        switch entry.attributes.kind {
        case .symbolicLink:
            throw SFTPFileOperationError.symbolicLinkTransferUnsupported(entry.name)
        case .directory:
            try FileManager.default.createDirectory(
                at: localURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o755]
            )
            do {
                for child in try listDirectoryUnlocked(remotePath) {
                    try Self.validatePathComponent(child.name)
                    try downloadItemUnlocked(
                        child,
                        remotePath: Self.appending(child.name, to: remotePath),
                        localURL: localURL.appending(path: child.name),
                        completed: &completed,
                        total: total,
                        progress: progress
                    )
                }
            } catch {
                try? FileManager.default.removeItem(at: localURL)
                throw error
            }
        case .regularFile, .other:
            let temporaryURL = localURL.deletingLastPathComponent()
                .appending(path: ".myterm-part-\(UUID().uuidString)")
            let remoteHandle = try openFileUnlocked(path: remotePath, flags: 0x0000_0001)
            var localHandle: FileHandle?
            var offset: UInt64 = 0
            do {
                guard FileManager.default.createFile(
                    atPath: temporaryURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let openedLocalHandle = try FileHandle(forWritingTo: temporaryURL)
                localHandle = openedLocalHandle
                while let chunk = try readFileUnlocked(handle: remoteHandle, offset: offset, length: 64 * 1_024) {
                    try openedLocalHandle.write(contentsOf: chunk)
                    let (nextOffset, overflow) = offset.addingReportingOverflow(UInt64(chunk.count))
                    guard !overflow else { throw SFTPProtocolError.malformedPacket }
                    offset = nextOffset
                    completed &+= UInt64(chunk.count)
                    progress(completed, total)
                }
                try closeHandle(remoteHandle)
                try openedLocalHandle.synchronize()
                try openedLocalHandle.close()
                localHandle = nil
                try FileManager.default.moveItem(at: temporaryURL, to: localURL)
            } catch {
                try? localHandle?.close()
                try? closeHandle(remoteHandle)
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
        }
    }

    private func removeRecursivelyUnlocked(path: String, kind: SFTPFileKind) throws {
        if kind == .directory {
            for entry in try listDirectoryUnlocked(path) {
                try Self.validatePathComponent(entry.name)
                try removeRecursivelyUnlocked(
                    path: Self.appending(entry.name, to: path),
                    kind: entry.attributes.kind
                )
            }
            let response = try request(type: SFTPPacketType.removeDirectory) { $0.append(string: path) }
            try requireOK(response)
        } else {
            try removeFileUnlocked(path)
        }
    }

    private func removeFileUnlocked(_ path: String) throws {
        let response = try request(type: SFTPPacketType.remove) { $0.append(string: path) }
        try requireOK(response)
    }

    private static func appending(_ name: String, to directory: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    private static func replaceLocalItem(at destination: URL, with replacement: URL) throws {
        let backup = destination.deletingLastPathComponent()
            .appending(path: ".myterm-backup-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: destination, to: backup)
        do {
            try FileManager.default.moveItem(at: replacement, to: destination)
        } catch {
            if !FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.moveItem(at: backup, to: destination)
            }
            throw error
        }
        try? FileManager.default.removeItem(at: backup)
    }

    private static func validatePathComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw SFTPFileOperationError.unsafeName(name)
        }
    }

    private func closeHandle(_ handle: Data) throws {
        let response = try request(type: SFTPPacketType.close) { $0.append(data: handle) }
        var (type, reader) = response
        guard type == SFTPPacketType.status else { throw SFTPProtocolError.unexpectedPacket(type) }
        _ = try SFTPProtocolCodec.parseStatus(&reader)
    }

    private func synchronized<T>(_ operation: () throws -> T) throws -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try operation()
    }

    deinit { session.close() }
}

extension SSHEnvironmentBuilder {
    static func environmentDictionary(
        from source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: environment(from: source).compactMap { item in
            guard let separator = item.firstIndex(of: "=") else { return nil }
            return (String(item[..<separator]), String(item[item.index(after: separator)...]))
        })
    }
}
