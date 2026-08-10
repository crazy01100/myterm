import Foundation

enum KnownHostsImportError: LocalizedError {
    case sourceMissing
    case sourceTooLarge
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .sourceMissing: "找不到 ~/.ssh/known_hosts。"
        case .sourceTooLarge: "known_hosts 超過 10 MB，為避免讀取異常檔案已停止匯入。"
        case .invalidEncoding: "known_hosts 不是有效的 UTF-8 文字檔。"
        }
    }
}

@MainActor
final class KnownHostsStore: ObservableObject {
    @Published private(set) var records: [KnownHostRecord] = []
    @Published private(set) var lastSyncedAt: Date?
    @Published var lastError: String?

    let sourceURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".ssh", directoryHint: .isDirectory)
        .appending(path: "known_hosts")

    init() {
        do {
            try AppPaths.prepare()
            try loadSnapshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    var sourceExists: Bool { FileManager.default.fileExists(atPath: sourceURL.path) }

    /// Called only from the explicit Import/Sync button. No file watching or
    /// background refresh is used.
    func syncFromSystem() throws {
        guard sourceExists else { throw KnownHostsImportError.sourceMissing }
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > 10 * 1_024 * 1_024 {
            throw KnownHostsImportError.sourceTooLarge
        }

        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw KnownHostsImportError.invalidEncoding
        }
        let importedRecords = KnownHostsParser.parse(contents)
        let syncDate = Date()
        let trustedSnapshot = importedRecords.map(\.rawLine).joined(separator: "\n")
            + (importedRecords.isEmpty ? "" : "\n")

        try Data(trustedSnapshot.utf8).write(to: AppPaths.importedKnownHostsRawFile, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.importedKnownHostsRawFile.path)

        let document = ImportedKnownHostsDocument(lastSyncedAt: syncDate, records: importedRecords)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: AppPaths.importedKnownHostsIndexFile, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.importedKnownHostsIndexFile.path)

        records = importedRecords
        lastSyncedAt = syncDate
    }

    private func loadSnapshot() throws {
        guard FileManager.default.fileExists(atPath: AppPaths.importedKnownHostsIndexFile.path) else { return }
        let data = try Data(contentsOf: AppPaths.importedKnownHostsIndexFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ImportedKnownHostsDocument.self, from: data)
        records = document.records
        lastSyncedAt = document.lastSyncedAt
    }
}
