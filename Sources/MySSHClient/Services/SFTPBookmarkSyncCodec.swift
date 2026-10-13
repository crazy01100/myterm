import Foundation

enum SFTPBookmarkSyncCodec {
    static func encrypt(_ value: BookmarkRemoteValue, projectID: String, ownerUID: String,
                        masterKey: VaultMasterKey, deviceID: UUID) throws -> EncryptedSyncRecord {
        guard value.revision > 0, value.revision < UInt64(Int64.max), value.value == nil || value.value?.id == value.id else { throw BookmarkSyncError.invalidData }
        let data: Data
        if let snippet = value.value {
            _ = try snippet.validated()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(snippet)
        } else { data = Data() }
        guard data.count <= BookmarkSyncPolicy.maximumCiphertext else { throw BookmarkSyncError.capacity }
        return try VaultRecordCrypto.encrypt(data, context: VaultRecordContext(
            ownerUID: BookmarkSyncPolicy.scope(project: projectID, uid: ownerUID), recordID: value.id,
            recordType: .sftpBookmark, keyVersion: masterKey.version, formatVersion: VaultCryptoFormat.recordVersion,
            revision: value.revision, modifiedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            modifiedByDeviceID: deviceID, deleted: value.value == nil), masterKey: masterKey)
    }
    static func decrypt(_ record: EncryptedSyncRecord, projectID: String, ownerUID: String,
                        masterKey: VaultMasterKey) throws -> BookmarkRemoteValue {
        guard record.recordType == .sftpBookmark, record.revision > 0, record.revision < UInt64(Int64.max),
              record.ciphertext.count <= BookmarkSyncPolicy.maximumCiphertext,
              record.deleted == record.ciphertext.isEmpty else { throw BookmarkSyncError.invalidData }
        let data = try VaultRecordCrypto.decrypt(record, ownerUID: BookmarkSyncPolicy.scope(project: projectID, uid: ownerUID), masterKey: masterKey)
        let value: RemoteDirectoryBookmark?
        if record.deleted { guard data.isEmpty else { throw BookmarkSyncError.invalidData }; value = nil }
        else {
            let decoded = try JSONDecoder().decode(RemoteDirectoryBookmark.self, from: data)
            guard decoded.id == record.id, try decoded.validated() == decoded else { throw BookmarkSyncError.invalidData }
            value = decoded
        }
        return .init(id: record.id, value: value, revision: record.revision)
    }
}
