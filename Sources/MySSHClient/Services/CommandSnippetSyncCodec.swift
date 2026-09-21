import Foundation

enum CommandSnippetSyncCodec {
    static func encrypt(_ value: SnippetRemoteValue, projectID: String, ownerUID: String,
                        masterKey: VaultMasterKey, deviceID: UUID) throws -> EncryptedSyncRecord {
        guard value.revision > 0, value.revision < UInt64(Int64.max), value.value == nil || value.value?.id == value.id else { throw SnippetSyncError.invalidData }
        let data: Data
        if let snippet = value.value {
            _ = try snippet.validated()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(snippet)
        } else { data = Data() }
        guard data.count <= SnippetSyncPolicy.maximumCiphertext else { throw SnippetSyncError.capacity }
        return try VaultRecordCrypto.encrypt(data, context: VaultRecordContext(
            ownerUID: SnippetSyncPolicy.scope(project: projectID, uid: ownerUID), recordID: value.id,
            recordType: .commandSnippet, keyVersion: masterKey.version, formatVersion: VaultCryptoFormat.recordVersion,
            revision: value.revision, modifiedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            modifiedByDeviceID: deviceID, deleted: value.value == nil), masterKey: masterKey)
    }
    static func decrypt(_ record: EncryptedSyncRecord, projectID: String, ownerUID: String,
                        masterKey: VaultMasterKey) throws -> SnippetRemoteValue {
        guard record.recordType == .commandSnippet, record.revision > 0, record.revision < UInt64(Int64.max),
              record.ciphertext.count <= SnippetSyncPolicy.maximumCiphertext,
              record.deleted == record.ciphertext.isEmpty else { throw SnippetSyncError.invalidData }
        let data = try VaultRecordCrypto.decrypt(record, ownerUID: SnippetSyncPolicy.scope(project: projectID, uid: ownerUID), masterKey: masterKey)
        let value: CommandSnippet?
        if record.deleted { guard data.isEmpty else { throw SnippetSyncError.invalidData }; value = nil }
        else {
            let decoded = try JSONDecoder().decode(CommandSnippet.self, from: data)
            guard decoded.id == record.id, try decoded.validated() == decoded else { throw SnippetSyncError.invalidData }
            value = decoded
        }
        return .init(id: record.id, value: value, revision: record.revision)
    }
}
