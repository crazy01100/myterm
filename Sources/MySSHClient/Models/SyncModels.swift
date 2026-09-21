import Foundation

enum SyncRecordType: String, Codable, CaseIterable, Sendable {
    case group
    case host
    case password
    case commandSnippet
    case connectionAudit
    case vaultKeyEnvelope
}

enum SyncMutationOperation: String, Codable, Sendable {
    case upsert
    case delete
}

/// A local journal entry intentionally contains no host fields or secrets.
/// The current local store is read and encrypted only when an uploader runs.
struct SyncMutation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordID: UUID
    let recordType: SyncRecordType
    let operation: SyncMutationOperation
    let sequence: UInt64
    let occurredAt: Date
    let deviceID: UUID

    init(
        id: UUID = UUID(),
        recordID: UUID,
        recordType: SyncRecordType,
        operation: SyncMutationOperation,
        sequence: UInt64,
        occurredAt: Date = .now,
        deviceID: UUID
    ) {
        self.id = id
        self.recordID = recordID
        self.recordType = recordType
        self.operation = operation
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.deviceID = deviceID
    }
}

/// The backend boundary accepts ciphertext only. Plain host/password models
/// must never be added to this type.
struct EncryptedSyncRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordType: SyncRecordType
    let ciphertext: Data
    let nonce: Data
    let authenticationTag: Data
    let keyVersion: UInt32
    let formatVersion: UInt32
    let revision: UInt64
    let modifiedAt: Date
    let modifiedByDeviceID: UUID
    let deleted: Bool
}

struct SyncChangePage: Codable, Equatable, Sendable {
    let records: [EncryptedSyncRecord]
    let nextCursor: String?
}
