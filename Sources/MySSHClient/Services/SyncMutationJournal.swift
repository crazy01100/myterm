import Foundation

enum SyncMutationJournalError: LocalizedError, Equatable {
    case invalidFile
    case tooManyEntries

    var errorDescription: String? {
        switch self {
        case .invalidFile: "同步變更佇列格式不正確。"
        case .tooManyEntries: "同步變更佇列超過安全上限，已停止加入新項目。"
        }
    }
}

private struct SyncMutationJournalDocument: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var entries: [SyncMutation]
}

/// Owner-only, metadata-free queue for changes waiting to be encrypted and
/// uploaded. The journal deliberately stores IDs and operations only.
final class SyncMutationJournal: @unchecked Sendable {
    static let maximumEntryCount = 10_000

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL = AppPaths.syncMutationJournalFile) {
        self.fileURL = fileURL
    }

    func entries() throws -> [SyncMutation] {
        try withLock { try loadUnlocked().entries }
    }

    @discardableResult
    func enqueue(
        recordID: UUID,
        recordType: SyncRecordType,
        operation: SyncMutationOperation,
        deviceID: UUID,
        occurredAt: Date = .now
    ) throws -> SyncMutation {
        try withLock {
            var document = try loadUnlocked()
            guard document.entries.count < Self.maximumEntryCount else {
                throw SyncMutationJournalError.tooManyEntries
            }
            let nextSequence = (document.entries.map(\.sequence).max() ?? 0) + 1
            let mutation = SyncMutation(
                recordID: recordID,
                recordType: recordType,
                operation: operation,
                sequence: nextSequence,
                occurredAt: occurredAt,
                deviceID: deviceID
            )
            document.entries.append(mutation)
            try writeUnlocked(document)
            return mutation
        }
    }

    func acknowledge(_ entryIDs: Set<UUID>) throws {
        guard !entryIDs.isEmpty else { return }
        try withLock {
            var document = try loadUnlocked()
            document.entries.removeAll { entryIDs.contains($0.id) }
            try writeUnlocked(document)
        }
    }

    func removeAll() throws {
        try withLock {
            try writeUnlocked(SyncMutationJournalDocument(entries: []))
        }
    }

    private func loadUnlocked() throws -> SyncMutationJournalDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SyncMutationJournalDocument(entries: [])
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(SyncMutationJournalDocument.self, from: data),
              document.schemaVersion == SyncMutationJournalDocument.currentSchemaVersion,
              document.entries.count <= Self.maximumEntryCount else {
            throw SyncMutationJournalError.invalidFile
        }
        return document
    }

    private func writeUnlocked(_ document: SyncMutationJournalDocument) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
