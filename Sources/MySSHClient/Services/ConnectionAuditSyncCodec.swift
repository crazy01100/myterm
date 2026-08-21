import Foundation

enum ConnectionAuditSyncCodecError: LocalizedError, Equatable {
    case invalidRecord
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "只有已結束且包含來源裝置的連線紀錄可以同步。"
        case .invalidPayload: "雲端連線紀錄格式不正確。"
        }
    }
}

enum ConnectionAuditSyncCodec {
    private static let fixedDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private static let fixedModifiedAt = Date(timeIntervalSince1970: 0)

    static func encrypt(
        _ record: ConnectionAuditRecord,
        ownerUID: String,
        masterKey: VaultMasterKey
    ) throws -> EncryptedSyncRecord {
        try validate(record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let plaintext = try encoder.encode(record)
        return try VaultRecordCrypto.encrypt(
            plaintext,
            context: context(recordID: record.id, ownerUID: ownerUID, masterKey: masterKey),
            masterKey: masterKey
        )
    }

    static func decrypt(
        _ encrypted: EncryptedSyncRecord,
        ownerUID: String,
        masterKey: VaultMasterKey
    ) throws -> ConnectionAuditRecord {
        guard encrypted.recordType == .connectionAudit,
              encrypted.revision == 1,
              encrypted.modifiedAt == fixedModifiedAt,
              encrypted.modifiedByDeviceID == fixedDeviceID,
              !encrypted.deleted else {
            throw ConnectionAuditSyncCodecError.invalidPayload
        }
        let plaintext = try VaultRecordCrypto.decrypt(
            encrypted,
            ownerUID: ownerUID,
            masterKey: masterKey
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let record = try? decoder.decode(ConnectionAuditRecord.self, from: plaintext),
              record.id == encrypted.id else {
            throw ConnectionAuditSyncCodecError.invalidPayload
        }
        try validate(record)
        return record
    }

    static func cloudRecord(
        id: UUID,
        ciphertext: Data,
        nonce: Data,
        authenticationTag: Data,
        keyVersion: UInt32,
        formatVersion: UInt32
    ) -> EncryptedSyncRecord {
        EncryptedSyncRecord(
            id: id,
            recordType: .connectionAudit,
            ciphertext: ciphertext,
            nonce: nonce,
            authenticationTag: authenticationTag,
            keyVersion: keyVersion,
            formatVersion: formatVersion,
            revision: 1,
            modifiedAt: fixedModifiedAt,
            modifiedByDeviceID: fixedDeviceID,
            deleted: false
        )
    }

    private static func context(
        recordID: UUID,
        ownerUID: String,
        masterKey: VaultMasterKey
    ) -> VaultRecordContext {
        VaultRecordContext(
            ownerUID: ownerUID,
            recordID: recordID,
            recordType: .connectionAudit,
            keyVersion: masterKey.version,
            formatVersion: VaultCryptoFormat.recordVersion,
            revision: 1,
            modifiedAt: fixedModifiedAt,
            modifiedByDeviceID: fixedDeviceID,
            deleted: false
        )
    }

    private static func validate(_ record: ConnectionAuditRecord) throws {
        guard !record.status.isOngoing,
              record.sourceDeviceID != nil,
              let deviceName = record.sourceDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceName.isEmpty,
              deviceName.count <= 128,
              record.connectionProtocol == "ssh",
              record.port > 0,
              record.port <= 65_535 else {
            throw ConnectionAuditSyncCodecError.invalidRecord
        }
    }
}
