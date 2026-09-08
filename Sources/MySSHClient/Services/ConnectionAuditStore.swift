import AppKit
import Combine
import Foundation

@MainActor
final class ConnectionAuditStore: ObservableObject {
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    @Published private(set) var records: [ConnectionAuditRecord]
    @Published private(set) var lastError: String?
    @Published private(set) var synchronizationRevision: UInt64 = 0

    private var index: ConnectionAuditIndex
    private let fileURL: URL
    private let now: () -> Date
    private let sourceDeviceID: UUID
    private let sourceDeviceName: String
    private var lastRetentionMaintenanceAt: Date?
    private var persistenceRevision: UInt64 = 0
    private var savedPersistenceRevision: UInt64 = 0
    private let persistenceQueue = DispatchQueue(
        label: "tw.local.MyTerm.connection-audit-persistence",
        qos: .utility
    )
    private var terminationObserver: NSObjectProtocol?

    init(
        fileURL: URL = AppPaths.connectionAuditLogFile,
        maximumRecordCount: Int = 5_000,
        now: @escaping () -> Date = Date.init,
        sourceDeviceID: UUID? = nil,
        sourceDeviceName: String? = nil
    ) {
        self.fileURL = fileURL
        self.now = now
        self.sourceDeviceID = sourceDeviceID
            ?? (try? SyncDeviceIdentityStore().loadOrCreate())
            ?? UUID()
        let fallbackName = ProcessInfo.processInfo.hostName
        let proposedName = sourceDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceDeviceName = String((proposedName?.isEmpty == false ? proposedName! : fallbackName).prefix(128))
        lastError = nil
        do {
            let document = try Self.loadDocument(from: fileURL)
            var loadedIndex = ConnectionAuditIndex(
                records: document.records,
                maximumRecordCount: maximumRecordCount
            )
            let recovered = loadedIndex.recoverInterruptedSessions()
            let backfilled = loadedIndex.backfillSourceDevice(
                id: self.sourceDeviceID,
                name: self.sourceDeviceName
            )
            let currentDate = now()
            let pruned = loadedIndex.pruneExpired(
                before: currentDate.addingTimeInterval(-Self.retentionInterval)
            )
            index = loadedIndex
            records = loadedIndex.newestFirst
            lastRetentionMaintenanceAt = currentDate
            if recovered || backfilled || pruned {
                if recovered { synchronizationRevision &+= 1 }
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
        index.begin(
            sessionID: sessionID,
            host: host,
            username: username,
            at: now(),
            sourceDeviceID: sourceDeviceID,
            sourceDeviceName: sourceDeviceName
        )
        publishAndPersist()
    }

    func markConnected(sessionID: UUID) {
        guard index.markConnected(sessionID: sessionID, at: now()) else { return }
        publishAndPersist()
    }

    func recordDetectedPlatform(sessionID: UUID, platform: HostPlatform) {
        let finalized = index.record(sessionID: sessionID)?.status.isOngoing == false
        guard index.recordDetectedPlatform(sessionID: sessionID, platform: platform) else { return }
        publishAndPersist(finalizedChange: finalized)
    }

    func finishCompleted(sessionID: UUID, exitCode: Int32?) {
        guard index.finish(
            sessionID: sessionID,
            status: .completed,
            at: now(),
            exitCode: exitCode
        ) else { return }
        publishAndPersist(finalizedChange: true)
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
        publishAndPersist(finalizedChange: true)
    }

    func finishCancelled(sessionID: UUID) {
        guard index.finish(sessionID: sessionID, status: .cancelled, at: now()) else { return }
        publishAndPersist(finalizedChange: true)
    }

    func performRetentionMaintenance(
        referenceDate: Date? = nil,
        force: Bool = false
    ) {
        let referenceDate = referenceDate ?? now()
        if !force,
           let lastRetentionMaintenanceAt,
           referenceDate.timeIntervalSince(lastRetentionMaintenanceAt) < 24 * 60 * 60 {
            return
        }
        lastRetentionMaintenanceAt = referenceDate
        guard index.pruneExpired(
            before: referenceDate.addingTimeInterval(-Self.retentionInterval)
        ) else { return }
        publishAndPersist()
    }

    func finalizedRecordsForSync(referenceDate: Date) -> [ConnectionAuditRecord] {
        performRetentionMaintenance(referenceDate: referenceDate, force: true)
        return index.newestFirst.filter { !$0.status.isOngoing }
    }

    func mergeFinalizedFromSync(
        _ incoming: [ConnectionAuditRecord],
        referenceDate: Date
    ) {
        let cutoff = referenceDate.addingTimeInterval(-Self.retentionInterval)
        let retained = incoming.filter {
            !$0.status.isOngoing && $0.retentionReferenceDate >= cutoff
        }
        guard index.mergeFinalized(retained) else {
            // A previous download may exist only in memory after a failed disk write.
            if savedPersistenceRevision != persistenceRevision { enqueuePersistence() }
            return
        }
        publishAndPersist()
    }

    /// Sync success includes durable local storage, not just a published in-memory merge.
    func persistForSync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            enqueuePersistence { result in continuation.resume(with: result) }
        }
    }

    private func publishAndPersist(finalizedChange: Bool = false) {
        records = index.newestFirst
        if finalizedChange { synchronizationRevision &+= 1 }
        enqueuePersistence()
    }

    private func enqueuePersistence(completion: ((Result<Void, Error>) -> Void)? = nil) {
        persistenceRevision &+= 1
        let revision = persistenceRevision
        let document = ConnectionAuditDocument(records: index.records)
        let fileURL = fileURL
        persistenceQueue.async { [weak self] in
            let result: Result<Void, Error>
            do {
                try Self.saveDocument(document, to: fileURL)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                if let self {
                    switch result {
                    case .success:
                        self.savedPersistenceRevision = revision
                        if revision == self.persistenceRevision { self.lastError = nil }
                    case .failure(let error):
                        if revision == self.persistenceRevision {
                            self.lastError = "連線紀錄暫時無法保存：\(error.localizedDescription)"
                        }
                    }
                }
                completion?(result)
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
