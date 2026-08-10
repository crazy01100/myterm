import Foundation

protocol SyncBackend: Sendable {
    func upload(_ records: [EncryptedSyncRecord]) async throws
    func changes(after cursor: String?) async throws -> SyncChangePage
}

enum SyncBackendError: LocalizedError, Equatable {
    case disabled

    var errorDescription: String? {
        switch self {
        case .disabled: "跨裝置同步尚未設定。MyTerm 仍會維持純本機模式。"
        }
    }
}

struct DisabledSyncBackend: SyncBackend {
    func upload(_ records: [EncryptedSyncRecord]) async throws {
        throw SyncBackendError.disabled
    }

    func changes(after cursor: String?) async throws -> SyncChangePage {
        throw SyncBackendError.disabled
    }
}

/// Deterministic backend used by unit tests. It never opens a network socket.
actor InMemorySyncBackend: SyncBackend {
    private var recordsByID: [UUID: EncryptedSyncRecord] = [:]

    func upload(_ records: [EncryptedSyncRecord]) async throws {
        for record in records {
            if let current = recordsByID[record.id], current.revision > record.revision {
                continue
            }
            recordsByID[record.id] = record
        }
    }

    func changes(after cursor: String?) async throws -> SyncChangePage {
        let records = recordsByID.values.sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.modifiedAt < $1.modifiedAt
        }
        return SyncChangePage(records: records, nextCursor: records.last?.id.uuidString)
    }
}
