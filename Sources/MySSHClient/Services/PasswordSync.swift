import CryptoKit
import Foundation

enum PasswordSyncError: LocalizedError, Equatable {
    case invalidPayload
    case passwordTooLarge
    case invalidBaseline
    case remoteRecordMissing
    case orphanedPassword
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPayload: "同步密碼資料格式不正確。"
        case .passwordTooLarge: "主機密碼超過同步安全上限。"
        case .invalidBaseline: "這台 Mac 的密碼同步基線格式不正確。"
        case .remoteRecordMissing: "雲端缺少原本已同步的密碼紀錄，已停止以避免覆蓋。"
        case .orphanedPassword: "雲端密碼找不到對應主機，已停止以避免套用到錯誤主機。"
        case .verificationFailed: "密碼同步後回讀驗證失敗。"
        }
    }
}

private struct SyncedPasswordPayload: Codable, Equatable {
    let schemaVersion: UInt32
    let hostID: UUID
    let passwordData: Data
}

enum PasswordSyncCodec {
    static let maximumPasswordSize = 4 * 1024

    static func recordID(for hostID: UUID) -> UUID {
        var input = Data("MyTerm.Password.RecordID.v1".utf8)
        var uuid = hostID.uuid
        withUnsafeBytes(of: &uuid) { input.append(contentsOf: $0) }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func contentDigest(
        passwordData: Data,
        hostID: UUID,
        masterKey: VaultMasterKey
    ) throws -> String {
        try validate(passwordData)
        var info = Data("MyTerm.Password.Digest.v1".utf8)
        var uuid = hostID.uuid
        withUnsafeBytes(of: &uuid) { info.append(contentsOf: $0) }
        let digestKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey.rawRepresentation),
            salt: Data("MyTerm.Password.Digest.Salt.v1".utf8),
            info: info,
            outputByteCount: 32
        )
        let authentication = HMAC<SHA256>.authenticationCode(for: passwordData, using: digestKey)
        return authentication.map { String(format: "%02x", $0) }.joined()
    }

    static func encrypt(
        passwordData: Data,
        hostID: UUID,
        ownerUID: String,
        masterKey: VaultMasterKey,
        revision: UInt64,
        modifiedByDeviceID: UUID,
        modifiedAt: Date = .now,
        nonce: Data? = nil
    ) throws -> EncryptedSyncRecord {
        try validate(passwordData)
        let recordID = recordID(for: hostID)
        let plaintext = try JSONEncoder.passwordSync.encode(
            SyncedPasswordPayload(schemaVersion: 1, hostID: hostID, passwordData: passwordData)
        )
        return try VaultRecordCrypto.encrypt(
            plaintext,
            context: VaultRecordContext(
                ownerUID: ownerUID,
                recordID: recordID,
                recordType: .password,
                keyVersion: masterKey.version,
                formatVersion: VaultCryptoFormat.recordVersion,
                revision: revision,
                modifiedAt: modifiedAt,
                modifiedByDeviceID: modifiedByDeviceID,
                deleted: false
            ),
            masterKey: masterKey,
            nonce: nonce
        )
    }

    static func decrypt(
        _ record: EncryptedSyncRecord,
        ownerUID: String,
        masterKey: VaultMasterKey
    ) throws -> (hostID: UUID, passwordData: Data) {
        guard record.recordType == .password, !record.deleted else {
            throw PasswordSyncError.invalidPayload
        }
        let plaintext = try VaultRecordCrypto.decrypt(record, ownerUID: ownerUID, masterKey: masterKey)
        guard plaintext.count <= maximumPasswordSize + 1024,
              let payload = try? JSONDecoder.passwordSync.decode(SyncedPasswordPayload.self, from: plaintext),
              payload.schemaVersion == 1,
              record.id == recordID(for: payload.hostID) else {
            throw PasswordSyncError.invalidPayload
        }
        try validate(payload.passwordData)
        return (payload.hostID, payload.passwordData)
    }

    static func tombstone(
        recordID: UUID,
        ownerUID: String,
        masterKey: VaultMasterKey,
        revision: UInt64,
        modifiedByDeviceID: UUID,
        modifiedAt: Date = .now
    ) throws -> EncryptedSyncRecord {
        try VaultRecordCrypto.encrypt(
            Data(),
            context: VaultRecordContext(
                ownerUID: ownerUID,
                recordID: recordID,
                recordType: .password,
                keyVersion: masterKey.version,
                formatVersion: VaultCryptoFormat.recordVersion,
                revision: revision,
                modifiedAt: modifiedAt,
                modifiedByDeviceID: modifiedByDeviceID,
                deleted: true
            ),
            masterKey: masterKey
        )
    }

    static func validateTombstone(
        _ record: EncryptedSyncRecord,
        ownerUID: String,
        masterKey: VaultMasterKey
    ) throws {
        guard record.recordType == .password, record.deleted else {
            throw PasswordSyncError.invalidPayload
        }
        let plaintext = try VaultRecordCrypto.decrypt(record, ownerUID: ownerUID, masterKey: masterKey)
        guard plaintext.isEmpty else { throw PasswordSyncError.invalidPayload }
    }

    private static func validate(_ data: Data) throws {
        guard !data.isEmpty else { throw PasswordSyncError.invalidPayload }
        guard data.count <= maximumPasswordSize else { throw PasswordSyncError.passwordTooLarge }
    }
}

struct PasswordSyncBaselineEntry: Codable, Equatable, Sendable {
    let recordID: UUID
    let hostID: UUID
    let remoteRevision: UInt64
    let localSecretDigest: String
    let remoteRecordDigest: String
}

struct PasswordSyncBaseline: Codable, Equatable, Sendable {
    static let schemaVersion: UInt32 = 1
    let schemaVersion: UInt32
    let ownerUIDDigest: String
    let deviceID: UUID
    let entries: [PasswordSyncBaselineEntry]
}

struct PasswordSyncBaselineStore: Sendable {
    let directoryURL: URL

    init(directoryURL: URL = AppPaths.syncDirectory) {
        self.directoryURL = directoryURL
    }

    func load(ownerUID: String) throws -> PasswordSyncBaseline? {
        let url = fileURL(ownerUID: ownerUID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024,
              let baseline = try? JSONDecoder.passwordSync.decode(PasswordSyncBaseline.self, from: data),
              baseline.schemaVersion == PasswordSyncBaseline.schemaVersion,
              baseline.ownerUIDDigest == MetadataSyncBaselineStore.ownerDigest(ownerUID),
              baseline.entries.count <= MetadataSyncPreviewPlanner.maximumRecordCount,
              Set(baseline.entries.map(\.recordID)).count == baseline.entries.count,
              baseline.entries.allSatisfy({
                  $0.recordID == PasswordSyncCodec.recordID(for: $0.hostID)
                      && $0.remoteRevision > 0
                      && $0.localSecretDigest.count == 64
                      && $0.remoteRecordDigest.count == 64
              }) else {
            throw PasswordSyncError.invalidBaseline
        }
        return baseline
    }

    func save(_ baseline: PasswordSyncBaseline, ownerUID: String) throws {
        guard baseline.schemaVersion == PasswordSyncBaseline.schemaVersion,
              baseline.ownerUIDDigest == MetadataSyncBaselineStore.ownerDigest(ownerUID) else {
            throw PasswordSyncError.invalidBaseline
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let data = try JSONEncoder.passwordSync.encode(baseline)
        try data.write(to: fileURL(ownerUID: ownerUID), options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL(ownerUID: ownerUID).path
        )
    }

    private func fileURL(ownerUID: String) -> URL {
        directoryURL.appending(
            path: "password-baseline-\(MetadataSyncBaselineStore.ownerDigest(ownerUID)).json"
        )
    }
}

struct PasswordSyncPendingConfirmation: Equatable, Sendable {
    let signature: String
    let names: [String]
}

enum PasswordSyncOutcome: Equatable, Sendable {
    case completed(uploaded: Int, downloaded: Int)
    case needsRecentOverwriteConfirmation(PasswordSyncPendingConfirmation)
}

enum PasswordSyncConflictResolution: Sendable {
    case preferLocal
    case preferRemote

    var downloadsRemoteConflict: Bool { self == .preferRemote }
}

struct PasswordSyncService: Sendable {
    func synchronize(
        hosts: [HostProfile],
        snapshot: FirestoreMetadataSnapshot,
        backend: FirestoreMetadataBackend,
        ownerUID: String,
        idToken: String,
        masterKey: VaultMasterKey,
        deviceID: UUID,
        forceRecentOverwrite: Bool,
        conflictResolution: PasswordSyncConflictResolution = .preferLocal
    ) async throws -> PasswordSyncOutcome {
        let hostByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        let baselineStore = PasswordSyncBaselineStore()
        var baseline = try baselineStore.load(ownerUID: ownerUID) ?? PasswordSyncBaseline(
            schemaVersion: PasswordSyncBaseline.schemaVersion,
            ownerUIDDigest: MetadataSyncBaselineStore.ownerDigest(ownerUID),
            deviceID: deviceID,
            entries: []
        )
        guard baseline.deviceID == deviceID else { throw PasswordSyncError.invalidBaseline }

        var local: [UUID: LocalPassword] = [:]
        for host in hosts where host.authenticationMethod == .password {
            guard var data = try KeychainStore.unifiedPasswordData(for: host.id) else { continue }
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            let recordID = PasswordSyncCodec.recordID(for: host.id)
            local[recordID] = LocalPassword(
                hostID: host.id,
                name: host.displayName,
                passwordData: data,
                digest: try PasswordSyncCodec.contentDigest(
                    passwordData: data,
                    hostID: host.id,
                    masterKey: masterKey
                )
            )
        }

        var remote: [UUID: RemotePassword] = [:]
        var remoteTombstones: [UUID: EncryptedSyncRecord] = [:]
        var staleRemoteRecords: [UUID: EncryptedSyncRecord] = [:]
        for record in snapshot.records where record.recordType == .password {
            if record.deleted {
                try PasswordSyncCodec.validateTombstone(
                    record,
                    ownerUID: ownerUID,
                    masterKey: masterKey
                )
                guard remoteTombstones.updateValue(record, forKey: record.id) == nil else {
                    throw PasswordSyncError.invalidPayload
                }
                continue
            }
            let decrypted = try PasswordSyncCodec.decrypt(record, ownerUID: ownerUID, masterKey: masterKey)
            guard let host = hostByID[decrypted.hostID], host.authenticationMethod == .password else {
                staleRemoteRecords[record.id] = record
                continue
            }
            guard remote[record.id] == nil else { throw PasswordSyncError.invalidPayload }
            remote[record.id] = RemotePassword(
                hostID: decrypted.hostID,
                name: host.displayName,
                passwordData: decrypted.passwordData,
                digest: try PasswordSyncCodec.contentDigest(
                    passwordData: decrypted.passwordData,
                    hostID: decrypted.hostID,
                    masterKey: masterKey
                ),
                record: record,
                recordDigest: try MetadataSyncCodec.encryptedRecordDigest(record)
            )
        }

        let retiredRecordIDs = Set(remoteTombstones.keys).union(staleRemoteRecords.keys)
        if !retiredRecordIDs.isEmpty {
            baseline = removing(recordIDs: retiredRecordIDs, from: baseline)
        }
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.entries.map { ($0.recordID, $0) })
        guard baselineByID.count == baseline.entries.count else { throw PasswordSyncError.invalidBaseline }
        let allIDs = Set(local.keys).union(remote.keys).union(baselineByID.keys)
        var uploads: [UUID] = []
        var downloads: [UUID] = []
        var repairs: [UUID] = []
        var conflicts: [UUID] = []

        for id in allIDs {
            let localValue = local[id]
            let remoteValue = remote[id]
            let base = baselineByID[id]
            switch (localValue, remoteValue, base) {
            case (.some, nil, nil): uploads.append(id)
            case (nil, .some, nil): downloads.append(id)
            case (.some(let localValue), .some(let remoteValue), nil):
                if localValue.digest == remoteValue.digest { repairs.append(id) }
                else if conflictResolution.downloadsRemoteConflict { downloads.append(id) }
                else { conflicts.append(id) }
            case (nil, nil, .some): throw PasswordSyncError.remoteRecordMissing
            case (.some, nil, .some): throw PasswordSyncError.remoteRecordMissing
            case (nil, .some, .some): downloads.append(id)
            case (.some(let localValue), .some(let remoteValue), .some(let base)):
                let localSame = localValue.digest == base.localSecretDigest
                let remoteSame = remoteValue.record.revision == base.remoteRevision
                    && remoteValue.recordDigest == base.remoteRecordDigest
                if localSame && remoteSame { break }
                if !localSame && remoteSame { uploads.append(id); break }
                if localSame && !remoteSame { downloads.append(id); break }
                if localValue.digest == remoteValue.digest { repairs.append(id); break }
                if conflictResolution.downloadsRemoteConflict { downloads.append(id) }
                else { conflicts.append(id) }
            case (nil, nil, nil): break
            }
        }

        let recentConflicts = conflicts.filter {
            RecentCloudUpdatePolicy.requiresConfirmation(
                updateTime: snapshot.updateTimes[$0],
                serverDate: snapshot.serverDate
            )
        }
        if !recentConflicts.isEmpty && !forceRecentOverwrite {
            let signature = try recentConflicts.sorted(by: { $0.uuidString < $1.uuidString }).map { id in
                guard let localValue = local[id], let remoteValue = remote[id] else {
                    throw PasswordSyncError.verificationFailed
                }
                return "password:\(id.uuidString):\(remoteValue.record.revision):\(localValue.digest)"
            }.joined(separator: "|")
            let names = recentConflicts.compactMap { local[$0]?.name }.sorted()
            return .needsRecentOverwriteConfirmation(
                PasswordSyncPendingConfirmation(signature: signature, names: names)
            )
        }

        var uploaded = 0
        var downloaded = 0
        for id in downloads {
            guard let remoteValue = remote[id] else { throw PasswordSyncError.verificationFailed }
            var data = remoteValue.passwordData
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            try KeychainStore.save(passwordData: data, for: remoteValue.hostID)
            baseline = replacing(
                entry: PasswordSyncBaselineEntry(
                    recordID: id,
                    hostID: remoteValue.hostID,
                    remoteRevision: remoteValue.record.revision,
                    localSecretDigest: remoteValue.digest,
                    remoteRecordDigest: remoteValue.recordDigest
                ),
                in: baseline
            )
            try baselineStore.save(baseline, ownerUID: ownerUID)
            downloaded += 1
        }

        for id in repairs {
            guard let localValue = local[id], let remoteValue = remote[id] else {
                throw PasswordSyncError.verificationFailed
            }
            baseline = replacing(
                entry: PasswordSyncBaselineEntry(
                    recordID: id,
                    hostID: localValue.hostID,
                    remoteRevision: remoteValue.record.revision,
                    localSecretDigest: localValue.digest,
                    remoteRecordDigest: remoteValue.recordDigest
                ),
                in: baseline
            )
            try baselineStore.save(baseline, ownerUID: ownerUID)
        }

        for id in uploads + conflicts {
            guard let localValue = local[id] else { throw PasswordSyncError.verificationFailed }
            let remoteValue = remote[id]
            let revision = remoteValue.map { $0.record.revision + 1 } ?? 1
            var data = localValue.passwordData
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            let pending = try PasswordSyncCodec.encrypt(
                passwordData: data,
                hostID: localValue.hostID,
                ownerUID: ownerUID,
                masterKey: masterKey,
                revision: revision,
                modifiedByDeviceID: deviceID
            )
            let saved: EncryptedSyncRecord
            if remoteValue != nil || remoteTombstones[id] != nil {
                let adjusted: EncryptedSyncRecord
                if let tombstone = remoteTombstones[id] {
                    adjusted = try PasswordSyncCodec.encrypt(
                        passwordData: data,
                        hostID: localValue.hostID,
                        ownerUID: ownerUID,
                        masterKey: masterKey,
                        revision: tombstone.revision + 1,
                        modifiedByDeviceID: deviceID
                    )
                } else {
                    adjusted = pending
                }
                saved = try await backend.upsert(adjusted, ownerUID: ownerUID, idToken: idToken)
            } else {
                saved = try await backend.create(pending, ownerUID: ownerUID, idToken: idToken)
            }
            baseline = replacing(
                entry: PasswordSyncBaselineEntry(
                    recordID: id,
                    hostID: localValue.hostID,
                    remoteRevision: saved.revision,
                    localSecretDigest: localValue.digest,
                    remoteRecordDigest: try MetadataSyncCodec.encryptedRecordDigest(saved)
                ),
                in: baseline
            )
            try baselineStore.save(baseline, ownerUID: ownerUID)
            uploaded += 1
        }

        for record in staleRemoteRecords.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let tombstone = try PasswordSyncCodec.tombstone(
                recordID: record.id,
                ownerUID: ownerUID,
                masterKey: masterKey,
                revision: record.revision + 1,
                modifiedByDeviceID: deviceID
            )
            _ = try await backend.upsert(tombstone, ownerUID: ownerUID, idToken: idToken)
        }
        if !staleRemoteRecords.isEmpty || !remoteTombstones.isEmpty {
            baseline = removing(
                recordIDs: Set(staleRemoteRecords.keys).union(remoteTombstones.keys),
                from: baseline
            )
            try baselineStore.save(baseline, ownerUID: ownerUID)
        }

        let verification = try await backend.fetchSnapshot(ownerUID: ownerUID, idToken: idToken)
        let allRemotePasswords = verification.records.filter { $0.recordType == .password }
        for tombstone in allRemotePasswords where tombstone.deleted {
            try PasswordSyncCodec.validateTombstone(
                tombstone,
                ownerUID: ownerUID,
                masterKey: masterKey
            )
        }
        let remotePasswords = allRemotePasswords.filter { !$0.deleted }
        var verifiedIDs: Set<UUID> = []
        for record in remotePasswords {
            let decrypted = try PasswordSyncCodec.decrypt(record, ownerUID: ownerUID, masterKey: masterKey)
            guard var localData = try KeychainStore.unifiedPasswordData(for: decrypted.hostID) else {
                throw PasswordSyncError.verificationFailed
            }
            defer { localData.resetBytes(in: localData.startIndex..<localData.endIndex) }
            var remoteData = decrypted.passwordData
            defer { remoteData.resetBytes(in: remoteData.startIndex..<remoteData.endIndex) }
            guard localData == remoteData,
                  let entry = baseline.entries.first(where: { $0.recordID == record.id }),
                  entry.remoteRevision == record.revision,
                  entry.remoteRecordDigest == (try MetadataSyncCodec.encryptedRecordDigest(record)) else {
                throw PasswordSyncError.verificationFailed
            }
            verifiedIDs.insert(record.id)
        }
        let localPasswordIDs = Set(hosts.filter {
            $0.authenticationMethod == .password
                && KeychainStore.containsUnifiedPassword(for: $0.id)
        }.map { PasswordSyncCodec.recordID(for: $0.id) })
        guard verifiedIDs == localPasswordIDs else { throw PasswordSyncError.verificationFailed }
        try baselineStore.save(baseline, ownerUID: ownerUID)
        return .completed(uploaded: uploaded, downloaded: downloaded)
    }

    private func replacing(
        entry: PasswordSyncBaselineEntry,
        in baseline: PasswordSyncBaseline
    ) -> PasswordSyncBaseline {
        var entries = baseline.entries.filter { $0.recordID != entry.recordID }
        entries.append(entry)
        entries.sort { $0.recordID.uuidString < $1.recordID.uuidString }
        return PasswordSyncBaseline(
            schemaVersion: baseline.schemaVersion,
            ownerUIDDigest: baseline.ownerUIDDigest,
            deviceID: baseline.deviceID,
            entries: entries
        )
    }

    private func removing(
        recordIDs: Set<UUID>,
        from baseline: PasswordSyncBaseline
    ) -> PasswordSyncBaseline {
        PasswordSyncBaseline(
            schemaVersion: baseline.schemaVersion,
            ownerUIDDigest: baseline.ownerUIDDigest,
            deviceID: baseline.deviceID,
            entries: baseline.entries.filter { !recordIDs.contains($0.recordID) }
        )
    }
}

private struct LocalPassword {
    let hostID: UUID
    let name: String
    var passwordData: Data
    let digest: String
}

private struct RemotePassword {
    let hostID: UUID
    let name: String
    var passwordData: Data
    let digest: String
    let record: EncryptedSyncRecord
    let recordDigest: String
}

private extension JSONEncoder {
    static var passwordSync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var passwordSync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
