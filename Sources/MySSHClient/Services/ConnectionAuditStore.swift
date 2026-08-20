import AppKit
import Combine
import Foundation

@MainActor
final class ConnectionAuditStore: ObservableObject {
    @Published private(set) var records: [ConnectionAuditRecord]
    @Published private(set) var lastError: String?

    private var index: ConnectionAuditIndex
    private let fileURL: URL
    private let now: () -> Date
    private let persistenceQueue = DispatchQueue(
        label: "tw.local.MyTerm.connection-audit-persistence",
        qos: .utility
    )
    private var terminationObserver: NSObjectProtocol?

    init(
        fileURL: URL = AppPaths.connectionAuditLogFile,
        maximumRecordCount: Int = 5_000,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.now = now
        lastError = nil
        do {
            let document = try Self.loadDocument(from: fileURL)
            var loadedIndex = ConnectionAuditIndex(
                records: document.records,
                maximumRecordCount: maximumRecordCount
            )
            let recovered = loadedIndex.recoverInterruptedSessions()
            index = loadedIndex
            records = loadedIndex.newestFirst
            if recovered {
                enqueuePersistence()
            }
        } catch {
            index = ConnectionAuditIndex(maximumRecordCount: maximumRecordCount)
            records = []
            lastError = "無法讀取既有連線紀錄；已保留損壞備份並以空白記錄啟動。"
        }
        let persistenceQueue = persistenceQueue
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Normal app termination is outside the SSH/UI hot path. Wait for
            // already-enqueued atomic writes so the final state is not falsely
            // recovered as interrupted on the next launch.
            persistenceQueue.sync { }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func begin(sessionID: UUID, host: HostProfile, username: String) {
        index.begin(sessionID: sessionID, host: host, username: username, at: now())
        publishAndPersist()
    }

    func markConnected(sessionID: UUID) {
        guard index.markConnected(sessionID: sessionID, at: now()) else { return }
        publishAndPersist()
    }

    func recordDetectedPlatform(sessionID: UUID, platform: HostPlatform) {
        guard index.recordDetectedPlatform(sessionID: sessionID, platform: platform) else { return }
        publishAndPersist()
    }

    func finishCompleted(sessionID: UUID, exitCode: Int32?) {
        guard index.finish(
            sessionID: sessionID,
            status: .completed,
            at: now(),
            exitCode: exitCode
        ) else { return }
        publishAndPersist()
    }

    func finishFailed(
        sessionID: UUID,
        exitCode: Int32?,
        failureCode: String,
        failureTitle: String
    ) {
        guard index.finish(
            sessionID: sessionID,
            status: .failed,
            at: now(),
            exitCode: exitCode,
            failureCode: failureCode,
            failureTitle: failureTitle
        ) else { return }
        publishAndPersist()
    }

    func finishCancelled(sessionID: UUID) {
        guard index.finish(sessionID: sessionID, status: .cancelled, at: now()) else { return }
        publishAndPersist()
    }

    func remove(recordID: UUID) {
        guard index.remove(recordID: recordID) else { return }
        publishAndPersist()
    }

    func removeAll() {
        guard index.removeAll() else { return }
        publishAndPersist()
    }

    private func publishAndPersist() {
        records = index.newestFirst
        enqueuePersistence()
    }

    private func enqueuePersistence() {
        let document = ConnectionAuditDocument(records: index.records)
        let fileURL = fileURL
        persistenceQueue.async { [weak self] in
            do {
                try Self.saveDocument(document, to: fileURL)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = "連線紀錄暫時無法保存：\(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated static func loadDocument(
        from fileURL: URL,
        fileManager: FileManager = .default
    ) throws -> ConnectionAuditDocument {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ConnectionAuditDocument(records: [])
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let document = try decoder.decode(ConnectionAuditDocument.self, from: data)
            guard document.schemaVersion == ConnectionAuditDocument.currentSchemaVersion else {
                throw ConnectionAuditStoreError.unsupportedSchema(document.schemaVersion)
            }
            return document
        } catch {
            let backup = fileURL.deletingLastPathComponent().appending(
                path: "connection-audit-log-corrupt-\(UUID().uuidString).json"
            )
            try? fileManager.moveItem(at: fileURL, to: backup)
            throw error
        }
    }

    nonisolated static func saveDocument(
        _ document: ConnectionAuditDocument,
        to fileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum ConnectionAuditStoreError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "不支援的連線紀錄格式版本：\(version)"
        }
    }
}
