import CryptoKit
import Foundation

enum MetadataSyncCodecError: LocalizedError, Equatable {
    case unsupportedRecordType
    case invalidPayload
    case payloadTooLarge
    case recordIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedRecordType: "這筆同步資料不是主機或群組。"
        case .invalidPayload: "同步主機或群組的資料格式不正確。"
        case .payloadTooLarge: "同步主機或群組資料超過安全大小限制。"
        case .recordIdentityMismatch: "同步資料的識別碼與加密紀錄不一致。"
        }
    }
}

enum DecryptedMetadataRecord: Equatable {
    case group(HostGroup)
    case host(HostProfile)
    case tombstone(recordID: UUID, recordType: SyncRecordType)
}

enum MetadataSyncCodec {
    static let maximumGroupPayloadSize = 16 * 1024
    static let maximumHostPayloadSize = 64 * 1024

    static func contentDigest(group: HostGroup) throws -> String {
        let payload = SyncedGroupPayload(group: group)
        try validate(payload)
        return SHA256.hash(data: try JSONEncoder.metadataSync.encode(payload)).hexString
    }

    static func contentDigest(host: HostProfile) throws -> String {
        let payload = SyncedHostPayload(host: host)
        try validate(payload)
        return SHA256.hash(data: try JSONEncoder.metadataSync.encode(payload)).hexString
    }

    static func encryptedRecordDigest(_ record: EncryptedSyncRecord) throws -> String {
        SHA256.hash(data: try JSONEncoder.metadataSync.encode(record)).hexString
    }

    static func encrypt(
        group: HostGroup,
        ownerUID: String,
        masterKey: VaultMasterKey,
        revision: UInt64,
        modifiedByDeviceID: UUID,
        nonce: Data? = nil
    ) throws -> EncryptedSyncRecord {
        let payload = SyncedGroupPayload(group: group)
        try validate(payload)
        let plaintext = try JSONEncoder.metadataSync.encode(payload)
        guard plaintext.count <= maximumGroupPayloadSize else {
            throw MetadataSyncCodecError.payloadTooLarge
        }
        return try VaultRecordCrypto.encrypt(
            plaintext,
            context: VaultRecordContext(
                ownerUID: ownerUID,
                recordID: group.id,
                recordType: .group,
                keyVersion: masterKey.version,
                formatVersion: VaultCryptoFormat.recordVersion,
                revision: revision,
                modifiedAt: group.createdAt,
                modifiedByDeviceID: modifiedByDeviceID,
                deleted: false
            ),
            masterKey: masterKey,
            nonce: nonce
        )
    }

    static func encrypt(
        host: HostProfile,
        ownerUID: String,
        masterKey: VaultMasterKey,
        revision: UInt64,
        modifiedByDeviceID: UUID,
        nonce: Data? = nil
    ) throws -> EncryptedSyncRecord {
        let payload = SyncedHostPayload(host: host)
        try validate(payload)
        let plaintext = try JSONEncoder.metadataSync.encode(payload)
        guard plaintext.count <= maximumHostPayloadSize else {
            throw MetadataSyncCodecError.payloadTooLarge
        }
        return try VaultRecordCrypto.encrypt(
            plaintext,
            context: VaultRecordContext(
                ownerUID: ownerUID,
                recordID: host.id,
                recordType: .host,
                keyVersion: masterKey.version,
                formatVersion: VaultCryptoFormat.recordVersion,
                revision: revision,
                modifiedAt: host.updatedAt,
                modifiedByDeviceID: modifiedByDeviceID,
                deleted: false
            ),
            masterKey: masterKey,
            nonce: nonce
        )
    }

    static func tombstone(
        recordID: UUID,
        recordType: SyncRecordType,
        ownerUID: String,
        masterKey: VaultMasterKey,
        revision: UInt64,
        modifiedAt: Date,
        modifiedByDeviceID: UUID,
        nonce: Data? = nil
    ) throws -> EncryptedSyncRecord {
        guard recordType == .host || recordType == .group else {
            throw MetadataSyncCodecError.unsupportedRecordType
        }
        return try VaultRecordCrypto.encrypt(
            Data(),
            context: VaultRecordContext(
                ownerUID: ownerUID,
                recordID: recordID,
                recordType: recordType,
                keyVersion: masterKey.version,
                formatVersion: VaultCryptoFormat.recordVersion,
                revision: revision,
                modifiedAt: modifiedAt,
                modifiedByDeviceID: modifiedByDeviceID,
                deleted: true
            ),
            masterKey: masterKey,
            nonce: nonce
        )
    }

    static func decrypt(
        _ record: EncryptedSyncRecord,
        ownerUID: String,
        masterKey: VaultMasterKey
    ) throws -> DecryptedMetadataRecord {
        guard record.recordType == .host || record.recordType == .group else {
            throw MetadataSyncCodecError.unsupportedRecordType
        }
        let plaintext = try VaultRecordCrypto.decrypt(record, ownerUID: ownerUID, masterKey: masterKey)
        if record.deleted {
            guard plaintext.isEmpty else { throw MetadataSyncCodecError.invalidPayload }
            return .tombstone(recordID: record.id, recordType: record.recordType)
        }
        switch record.recordType {
        case .group:
            guard plaintext.count <= maximumGroupPayloadSize,
                  let payload = try? JSONDecoder.metadataSync.decode(SyncedGroupPayload.self, from: plaintext) else {
                throw MetadataSyncCodecError.invalidPayload
            }
            guard payload.id == record.id else { throw MetadataSyncCodecError.recordIdentityMismatch }
            try validate(payload)
            return .group(payload.group)
        case .host:
            guard plaintext.count <= maximumHostPayloadSize,
                  let payload = try? JSONDecoder.metadataSync.decode(SyncedHostPayload.self, from: plaintext) else {
                throw MetadataSyncCodecError.invalidPayload
            }
            guard payload.id == record.id else { throw MetadataSyncCodecError.recordIdentityMismatch }
            try validate(payload)
            return .host(try payload.hostProfile())
        default:
            throw MetadataSyncCodecError.unsupportedRecordType
        }
    }

    private static func validate(_ payload: SyncedGroupPayload) throws {
        let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.schemaVersion == 1,
              !name.isEmpty,
              name.count <= 512,
              payload.parentID != payload.id else {
            throw MetadataSyncCodecError.invalidPayload
        }
    }

    private static func validate(_ payload: SyncedHostPayload) throws {
        guard payload.schemaVersion == 1,
              payload.name.count <= 512,
              payload.notes.count <= 16_384,
              payload.privateKeyRequired == (payload.authenticationMethod == .privateKey) else {
            throw MetadataSyncCodecError.invalidPayload
        }
        var candidate = payload.rawHostProfile
        if candidate.authenticationMethod == .privateKey {
            candidate.privateKeyPath = "/MyTerm/local-private-key-required"
        }
        do {
            _ = try candidate.validated()
        } catch {
            throw MetadataSyncCodecError.invalidPayload
        }
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private struct SyncedGroupPayload: Codable, Equatable {
    let schemaVersion: UInt32
    let id: UUID
    let name: String
    let parentID: UUID?
    let createdAt: Date

    init(group: HostGroup) {
        schemaVersion = 1
        id = group.id
        name = group.name
        parentID = group.parentID
        createdAt = group.createdAt
    }

    var group: HostGroup {
        HostGroup(id: id, name: name, parentID: parentID, createdAt: createdAt)
    }
}

private struct SyncedHostPayload: Codable, Equatable {
    let schemaVersion: UInt32
    let id: UUID
    let name: String
    let hostname: String
    let port: Int
    let username: String
    let groupID: UUID?
    let notes: String
    let authenticationMethod: AuthenticationMethod
    let privateKeyRequired: Bool
    let algorithmMode: AlgorithmMode
    let customAlgorithms: CustomAlgorithms
    let detectedPlatform: HostPlatform?
    let createdAt: Date
    let updatedAt: Date

    init(host: HostProfile) {
        schemaVersion = 1
        id = host.id
        name = host.name
        hostname = host.hostname
        port = host.port
        username = host.username
        groupID = host.groupID
        notes = host.notes
        authenticationMethod = host.authenticationMethod
        privateKeyRequired = host.authenticationMethod == .privateKey
        algorithmMode = host.algorithmMode
        customAlgorithms = host.customAlgorithms
        detectedPlatform = host.detectedPlatform
        createdAt = host.createdAt
        updatedAt = host.updatedAt
    }

    var rawHostProfile: HostProfile {
        var host = HostProfile()
        host.id = id
        host.name = name
        host.hostname = hostname
        host.port = port
        host.username = username
        host.groupID = groupID
        host.notes = notes
        host.authenticationMethod = authenticationMethod
        host.privateKeyPath = ""
        host.algorithmMode = algorithmMode
        host.customAlgorithms = customAlgorithms
        host.detectedPlatform = detectedPlatform
        host.createdAt = createdAt
        host.updatedAt = updatedAt
        return host
    }

    func hostProfile() throws -> HostProfile {
        var host = rawHostProfile
        if host.authenticationMethod == .privateKey {
            // A filesystem path is local-only. The receiving Mac must select
            // its own key before this authentication method can be used.
            host.privateKeyPath = ""
        }
        return host
    }
}

private extension JSONEncoder {
    static var metadataSync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var metadataSync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
