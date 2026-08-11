import Combine
import Foundation

enum UnifiedSyncSetupMode: Equatable {
    case create
    case restore

    var title: String {
        switch self {
        case .create: "建立同步密語"
        case .restore: "輸入同步密語"
        }
    }

    var requiresConfirmation: Bool { self == .create }
}

enum UnifiedSyncSetupState: Equatable {
    case idle
    case checking
    case awaitingPassphrase(UnifiedSyncSetupMode)
    case working(String)
    case needsCloudAdoption
    case completed(recoveryKey: String?)
    case failed(String)
}

enum UnifiedSyncSetupError: LocalizedError, Equatable {
    case signedOut
    case cloudChanged
    case incompatibleInventory
    case recentPasswordConflict
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .signedOut: "請先登入要用來同步的 Google 帳戶。"
        case .cloudChanged: "雲端保管庫在設定期間發生變更，請重新開始以避免覆蓋。"
        case .incompatibleInventory: "這台 Mac 與雲端有相同識別碼但內容不同的資料；請先執行同步功能檢測。"
        case .recentPasswordConflict: "這台 Mac 與雲端有近期密碼衝突；請先執行同步功能檢測。"
        case .verificationFailed: "同步啟用後的回讀驗證未通過，開關仍保持關閉。"
        }
    }
}

@MainActor
final class UnifiedSyncSetupStore: ObservableObject {
    @Published private(set) var state: UnifiedSyncSetupState = .idle

    private var preparationTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var preparedRemoteEnvelope: LocalVaultEnvelopeDocument?

    func prepare(accountStore: CloudAccountStore) {
        guard preparationTask == nil, activationTask == nil else { return }
        state = .checking
        preparationTask = Task { [weak self, weak accountStore] in
            guard let self, let accountStore else { return }
            do {
                guard case .signedIn(let account) = accountStore.state,
                      let projectID = accountStore.firebaseProjectID else {
                    throw UnifiedSyncSetupError.signedOut
                }
                let token = try await accountStore.validIDToken()
                let remote = try await FirestoreVaultBackend(projectID: projectID).fetchEnvelope(
                    ownerUID: account.uid,
                    idToken: token
                )
                self.preparedRemoteEnvelope = remote
                self.state = .awaitingPassphrase(remote == nil ? .create : .restore)
            } catch {
                self.state = .failed(error.localizedDescription)
            }
            self.preparationTask = nil
        }
    }

    func activate(
        passphrase: String,
        hostStore: HostStore,
        settings: SyncSettingsStore,
        accountStore: CloudAccountStore,
        vaultSetupStore: VaultSetupStore
    ) {
        guard activationTask == nil,
              case .awaitingPassphrase = state else { return }
        state = .working("正在建立端對端加密保管庫…")
        activationTask = Task { [weak self, weak hostStore, weak settings, weak accountStore, weak vaultSetupStore] in
            guard let self, let hostStore, let settings, let accountStore, let vaultSetupStore else { return }
            do {
                guard case .signedIn(let account) = accountStore.state,
                      let projectID = accountStore.firebaseProjectID else {
                    throw UnifiedSyncSetupError.signedOut
                }
                let token = try await accountStore.validIDToken()
                let envelopeBackend = FirestoreVaultBackend(projectID: projectID)
                let latestRemoteEnvelope = try await envelopeBackend.fetchEnvelope(
                    ownerUID: account.uid,
                    idToken: token
                )
                guard latestRemoteEnvelope == self.preparedRemoteEnvelope else {
                    throw UnifiedSyncSetupError.cloudChanged
                }

                let recoveryKey: String?
                let masterKey: VaultMasterKey
                if let remoteEnvelope = latestRemoteEnvelope {
                    self.state = .working("正在驗證同步密語並還原主金鑰…")
                    masterKey = try await Task.detached(priority: .userInitiated) {
                        try VaultSetupService.restoreWithPassphrase(
                            ownerUID: account.uid,
                            document: remoteEnvelope,
                            passphrase: passphrase
                        )
                    }.value
                    recoveryKey = nil
                } else if let localEnvelope = try VaultEnvelopeStore().load(ownerUID: account.uid) {
                    self.state = .working("正在驗證既有保管庫與同步密語…")
                    masterKey = try await Task.detached(priority: .userInitiated) {
                        try VaultSetupService.restoreWithPassphrase(
                            ownerUID: account.uid,
                            document: localEnvelope,
                            passphrase: passphrase
                        )
                    }.value
                    let confirmed = localEnvelope.recoveryConfirmedAt == nil
                        ? try VaultSetupService.confirmRecoveryKey(ownerUID: account.uid)
                        : localEnvelope
                    guard try await envelopeBackend.fetchEnvelope(
                        ownerUID: account.uid,
                        idToken: token
                    ) == nil else {
                        throw UnifiedSyncSetupError.cloudChanged
                    }
                    try await envelopeBackend.upsertEnvelope(
                        confirmed,
                        ownerUID: account.uid,
                        idToken: token
                    )
                    recoveryKey = nil
                } else {
                    self.state = .working("正在產生主金鑰與一次性復原金鑰…")
                    let creation = try await Task.detached(priority: .userInitiated) {
                        try VaultSetupService.create(ownerUID: account.uid, passphrase: passphrase)
                    }.value
                    guard try await envelopeBackend.fetchEnvelope(
                        ownerUID: account.uid,
                        idToken: token
                    ) == nil else {
                        throw UnifiedSyncSetupError.cloudChanged
                    }
                    let confirmed = try VaultSetupService.confirmRecoveryKey(ownerUID: account.uid)
                    try await envelopeBackend.upsertEnvelope(
                        confirmed,
                        ownerUID: account.uid,
                        idToken: token
                    )
                    guard let loaded = try VaultMasterKeyStore.load(
                        ownerUID: account.uid,
                        version: VaultCryptoFormat.masterKeyVersion
                    ) else {
                        throw VaultSetupError.missingLocalMasterKey
                    }
                    masterKey = loaded
                    recoveryKey = creation.recoveryKey
                }

                self.state = .working("正在安全合併主機與群組…")
                let metadataBackend = FirestoreMetadataBackend(projectID: projectID)
                let deviceID = try SyncDeviceIdentityStore().loadOrCreate()
                let metadataResult = try await Self.prepareMetadata(
                    groups: hostStore.groups,
                    hosts: hostStore.hosts,
                    backend: metadataBackend,
                    ownerUID: account.uid,
                    idToken: token,
                    masterKey: masterKey,
                    deviceID: deviceID
                )
                if Set(metadataResult.document.groups) != Set(hostStore.groups)
                    || Set(metadataResult.document.hosts) != Set(hostStore.hosts) {
                    _ = try hostStore.applyVerifiedCloudMerge(metadataResult.document)
                }
                try MetadataSyncBaselineStore().save(metadataResult.baseline, ownerUID: account.uid)

                self.state = .working("正在端對端加密同步已儲存密碼…")
                let passwordSnapshot = try await metadataBackend.fetchSnapshot(
                    ownerUID: account.uid,
                    idToken: token
                )
                let passwordOutcome = try await PasswordSyncService().synchronize(
                    hosts: metadataResult.document.hosts,
                    snapshot: passwordSnapshot,
                    backend: metadataBackend,
                    ownerUID: account.uid,
                    idToken: token,
                    masterKey: masterKey,
                    deviceID: deviceID,
                    forceRecentOverwrite: false
                )
                if case .needsRecentOverwriteConfirmation = passwordOutcome {
                    throw UnifiedSyncSetupError.recentPasswordConflict
                }

                self.state = .working("正在重新下載驗證完整同步結果…")
                let verifiedMetadata = try await metadataBackend.fetchAll(
                    ownerUID: account.uid,
                    idToken: token
                )
                let verifiedPlan = try MetadataManualSyncPlanner.makePlan(
                    localGroups: hostStore.groups,
                    localHosts: hostStore.hosts,
                    remoteRecords: verifiedMetadata,
                    baseline: metadataResult.baseline,
                    ownerUID: account.uid,
                    masterKey: masterKey
                )
                guard verifiedPlan.conflictCount == 0,
                      verifiedPlan.uploadCount == 0,
                      verifiedPlan.downloadCount == 0,
                      verifiedPlan.deletionCount == 0,
                      verifiedPlan.repairCount == 0,
                      verifiedPlan.unchangedCount == hostStore.groups.count + hostStore.hosts.count else {
                    throw UnifiedSyncSetupError.verificationFailed
                }

                try settings.setMetadataSyncEnabled(true)
                vaultSetupStore.refresh(account: account)
                await vaultSetupStore.checkCloudEnvelope(projectID: projectID, idToken: token)
                self.state = .completed(recoveryKey: recoveryKey)
            } catch {
                try? settings.setMetadataSyncEnabled(false)
                if error as? UnifiedSyncSetupError == .incompatibleInventory {
                    self.state = .needsCloudAdoption
                } else {
                    self.state = .failed(error.localizedDescription)
                }
            }
            self.activationTask = nil
        }
    }

    func adoptCloudData(
        hostStore: HostStore,
        settings: SyncSettingsStore,
        accountStore: CloudAccountStore,
        vaultSetupStore: VaultSetupStore
    ) {
        guard activationTask == nil, state == .needsCloudAdoption else { return }
        state = .working("正在備份本機資料並安全套用雲端版本…")
        activationTask = Task { [weak self, weak hostStore, weak settings, weak accountStore, weak vaultSetupStore] in
            guard let self, let hostStore, let settings, let accountStore, let vaultSetupStore else { return }
            do {
                guard case .signedIn(let account) = accountStore.state,
                      let projectID = accountStore.firebaseProjectID else {
                    throw UnifiedSyncSetupError.signedOut
                }
                let token = try await accountStore.validIDToken()
                let envelopeBackend = FirestoreVaultBackend(projectID: projectID)
                guard let remoteEnvelope = try await envelopeBackend.fetchEnvelope(
                    ownerUID: account.uid,
                    idToken: token
                ),
                      let localEnvelope = try VaultEnvelopeStore().load(ownerUID: account.uid),
                      remoteEnvelope == localEnvelope,
                      let masterKey = try VaultMasterKeyStore.load(
                        ownerUID: account.uid,
                        version: remoteEnvelope.passphraseEnvelope.masterKeyVersion
                      ) else {
                    throw UnifiedSyncSetupError.cloudChanged
                }

                let metadataBackend = FirestoreMetadataBackend(projectID: projectID)
                let remoteMetadata = try await metadataBackend.fetchAll(
                    ownerUID: account.uid,
                    idToken: token
                )
                let activeRemoteMetadata = remoteMetadata.filter { !$0.deleted }
                var cloudDocument = try Self.cloudInventory(
                    records: remoteMetadata,
                    ownerUID: account.uid,
                    masterKey: masterKey
                )
                let localPrivateKeyPaths = Dictionary(uniqueKeysWithValues: hostStore.hosts.compactMap { host in
                    host.privateKeyPath.isEmpty ? nil : (host.id, host.privateKeyPath)
                })
                for index in cloudDocument.hosts.indices {
                    if cloudDocument.hosts[index].authenticationMethod == .privateKey,
                       let localPath = localPrivateKeyPaths[cloudDocument.hosts[index].id] {
                        cloudDocument.hosts[index].privateKeyPath = localPath
                    }
                }
                _ = try hostStore.applyVerifiedCloudMerge(cloudDocument)

                let deviceID = try SyncDeviceIdentityStore().loadOrCreate()
                let metadataBaseline = try MetadataSyncBaselinePlanner.makeBaseline(
                    localGroups: cloudDocument.groups,
                    localHosts: cloudDocument.hosts,
                    remoteRecords: activeRemoteMetadata,
                    ownerUID: account.uid,
                    masterKey: masterKey,
                    deviceID: deviceID
                )
                try MetadataSyncBaselineStore().save(metadataBaseline, ownerUID: account.uid)

                self.state = .working("正在採用雲端密碼並建立這台 Mac 的同步基線…")
                try PasswordSyncBaselineStore().save(
                    PasswordSyncBaseline(
                        schemaVersion: PasswordSyncBaseline.schemaVersion,
                        ownerUIDDigest: MetadataSyncBaselineStore.ownerDigest(account.uid),
                        deviceID: deviceID,
                        entries: []
                    ),
                    ownerUID: account.uid
                )
                let passwordSnapshot = try await metadataBackend.fetchSnapshot(
                    ownerUID: account.uid,
                    idToken: token
                )
                let passwordOutcome = try await PasswordSyncService().synchronize(
                    hosts: cloudDocument.hosts,
                    snapshot: passwordSnapshot,
                    backend: metadataBackend,
                    ownerUID: account.uid,
                    idToken: token,
                    masterKey: masterKey,
                    deviceID: deviceID,
                    forceRecentOverwrite: true,
                    conflictResolution: .preferRemote
                )
                guard case .completed = passwordOutcome else {
                    throw UnifiedSyncSetupError.verificationFailed
                }

                self.state = .working("正在重新下載驗證完整同步結果…")
                let verifiedRemote = try await metadataBackend.fetchAll(
                    ownerUID: account.uid,
                    idToken: token
                )
                let verifiedPlan = try MetadataManualSyncPlanner.makePlan(
                    localGroups: hostStore.groups,
                    localHosts: hostStore.hosts,
                    remoteRecords: verifiedRemote,
                    baseline: metadataBaseline,
                    ownerUID: account.uid,
                    masterKey: masterKey
                )
                guard verifiedPlan.conflictCount == 0,
                      verifiedPlan.uploadCount == 0,
                      verifiedPlan.downloadCount == 0,
                      verifiedPlan.deletionCount == 0,
                      verifiedPlan.repairCount == 0,
                      verifiedPlan.unchangedCount == hostStore.groups.count + hostStore.hosts.count else {
                    throw UnifiedSyncSetupError.verificationFailed
                }

                try settings.setMetadataSyncEnabled(true)
                vaultSetupStore.refresh(account: account)
                await vaultSetupStore.checkCloudEnvelope(projectID: projectID, idToken: token)
                self.state = .completed(recoveryKey: nil)
            } catch {
                try? settings.setMetadataSyncEnabled(false)
                self.state = .failed(error.localizedDescription)
            }
            self.activationTask = nil
        }
    }

    func reset() {
        preparationTask?.cancel()
        activationTask?.cancel()
        preparationTask = nil
        activationTask = nil
        preparedRemoteEnvelope = nil
        state = .idle
    }

    private struct MetadataPreparationResult {
        let document: InventoryDocument
        let baseline: MetadataSyncBaseline
    }

    private static func cloudInventory(
        records: [EncryptedSyncRecord],
        ownerUID: String,
        masterKey: VaultMasterKey
    ) throws -> InventoryDocument {
        var groups: [HostGroup] = []
        var hosts: [HostProfile] = []
        for record in records {
            switch try MetadataSyncCodec.decrypt(record, ownerUID: ownerUID, masterKey: masterKey) {
            case .group(let group): groups.append(group)
            case .host(let host): hosts.append(host)
            case .tombstone: continue
            }
        }
        let document = InventoryDocument(groups: groups, hosts: hosts)
        try CloudInventoryRestoreValidator.validate(document)
        return document
    }

    private static func prepareMetadata(
        groups: [HostGroup],
        hosts: [HostProfile],
        backend: FirestoreMetadataBackend,
        ownerUID: String,
        idToken: String,
        masterKey: VaultMasterKey,
        deviceID: UUID
    ) async throws -> MetadataPreparationResult {
        let existingBaseline = try MetadataSyncBaselineStore().load(ownerUID: ownerUID)
        if let existingBaseline {
            let remote = try await backend.fetchAll(ownerUID: ownerUID, idToken: idToken)
            return try await reconcileExistingBaseline(
                localGroups: groups,
                localHosts: hosts,
                remoteRecords: remote,
                baseline: existingBaseline,
                ownerUID: ownerUID,
                idToken: idToken,
                masterKey: masterKey,
                backend: backend
            )
        }

        var remote = try await backend.fetchAll(ownerUID: ownerUID, idToken: idToken)
        var remoteGroups: [UUID: HostGroup] = [:]
        var remoteHosts: [UUID: HostProfile] = [:]
        var remoteTombstoneIDs: Set<UUID> = []
        for record in remote {
            switch try MetadataSyncCodec.decrypt(record, ownerUID: ownerUID, masterKey: masterKey) {
            case .group(let group): remoteGroups[group.id] = group
            case .host(let host): remoteHosts[host.id] = host
            case .tombstone(let recordID, _): remoteTombstoneIDs.insert(recordID)
            }
        }
        var mergedGroups = remoteGroups
        var mergedHosts = remoteHosts

        for group in groups {
            guard !remoteTombstoneIDs.contains(group.id) else {
                throw UnifiedSyncSetupError.incompatibleInventory
            }
            if let remoteGroup = remoteGroups[group.id] {
                guard try MetadataSyncCodec.contentDigest(group: group)
                    == MetadataSyncCodec.contentDigest(group: remoteGroup) else {
                    throw UnifiedSyncSetupError.incompatibleInventory
                }
            } else {
                let record = try MetadataSyncCodec.encrypt(
                    group: group,
                    ownerUID: ownerUID,
                    masterKey: masterKey,
                    revision: 1,
                    modifiedByDeviceID: deviceID
                )
                try await backend.create(record, ownerUID: ownerUID, idToken: idToken)
                mergedGroups[group.id] = group
            }
        }
        for host in hosts {
            guard !remoteTombstoneIDs.contains(host.id) else {
                throw UnifiedSyncSetupError.incompatibleInventory
            }
            if let remoteHost = remoteHosts[host.id] {
                guard try MetadataSyncCodec.contentDigest(host: host)
                    == MetadataSyncCodec.contentDigest(host: remoteHost) else {
                    throw UnifiedSyncSetupError.incompatibleInventory
                }
                var preserved = remoteHost
                preserved.privateKeyPath = host.privateKeyPath
                mergedHosts[host.id] = preserved
            } else {
                let record = try MetadataSyncCodec.encrypt(
                    host: host,
                    ownerUID: ownerUID,
                    masterKey: masterKey,
                    revision: 1,
                    modifiedByDeviceID: deviceID
                )
                try await backend.create(record, ownerUID: ownerUID, idToken: idToken)
                mergedHosts[host.id] = host
            }
        }

        let document = InventoryDocument(
            groups: Array(mergedGroups.values),
            hosts: Array(mergedHosts.values)
        )
        try MetadataMergedInventoryValidator.validate(document)
        remote = try await backend.fetchAll(ownerUID: ownerUID, idToken: idToken)
        guard remote.count == document.groups.count + document.hosts.count,
              Set(remote.map(\.id)) == Set(document.groups.map(\.id)).union(document.hosts.map(\.id)) else {
            throw UnifiedSyncSetupError.verificationFailed
        }
        let baseline: MetadataSyncBaseline
        if remote.isEmpty {
            baseline = MetadataSyncBaseline(
                schemaVersion: MetadataSyncBaselineStore.schemaVersion,
                ownerUIDDigest: MetadataSyncBaselineStore.ownerDigest(ownerUID),
                createdAt: .now,
                deviceID: deviceID,
                entries: []
            )
        } else {
            baseline = try MetadataSyncBaselinePlanner.makeBaseline(
                localGroups: document.groups,
                localHosts: document.hosts,
                remoteRecords: remote,
                ownerUID: ownerUID,
                masterKey: masterKey,
                deviceID: deviceID
            )
        }
        return MetadataPreparationResult(document: document, baseline: baseline)
    }

    private static func reconcileExistingBaseline(
        localGroups: [HostGroup],
        localHosts: [HostProfile],
        remoteRecords: [EncryptedSyncRecord],
        baseline: MetadataSyncBaseline,
        ownerUID: String,
        idToken: String,
        masterKey: VaultMasterKey,
        backend: FirestoreMetadataBackend
    ) async throws -> MetadataPreparationResult {
        let plan = try MetadataManualSyncPlanner.makePlan(
            localGroups: localGroups,
            localHosts: localHosts,
            remoteRecords: remoteRecords,
            baseline: baseline,
            ownerUID: ownerUID,
            masterKey: masterKey
        )
        guard plan.conflictCount == 0 else {
            throw UnifiedSyncSetupError.incompatibleInventory
        }

        var groups = Dictionary(uniqueKeysWithValues: localGroups.map { ($0.id, $0) })
        var hosts = Dictionary(uniqueKeysWithValues: localHosts.map { ($0.id, $0) })
        var updatedBaseline = baseline
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteRecords.map { ($0.id, $0) })
        let remoteApplyIDs = Set(plan.items.filter {
            $0.disposition == .download || $0.disposition == .remoteDeletion
        }.map(\.id))

        for record in remoteRecords where remoteApplyIDs.contains(record.id) {
            switch try MetadataSyncCodec.decrypt(record, ownerUID: ownerUID, masterKey: masterKey) {
            case .group(let group):
                groups[group.id] = group
                updatedBaseline = MetadataSyncBaselinePlanner.replacingEntry(
                    MetadataSyncBaselineEntry(
                        recordID: record.id,
                        recordType: record.recordType,
                        remoteRevision: record.revision,
                        localContentDigest: try MetadataSyncCodec.contentDigest(group: group),
                        remoteRecordDigest: try MetadataSyncCodec.encryptedRecordDigest(record)
                    ),
                    in: updatedBaseline
                )
            case .host(var host):
                if host.authenticationMethod == .privateKey,
                   let localPath = hosts[host.id]?.privateKeyPath,
                   !localPath.isEmpty {
                    host.privateKeyPath = localPath
                }
                hosts[host.id] = host
                updatedBaseline = MetadataSyncBaselinePlanner.replacingEntry(
                    MetadataSyncBaselineEntry(
                        recordID: record.id,
                        recordType: record.recordType,
                        remoteRevision: record.revision,
                        localContentDigest: try MetadataSyncCodec.contentDigest(host: host),
                        remoteRecordDigest: try MetadataSyncCodec.encryptedRecordDigest(record)
                    ),
                    in: updatedBaseline
                )
            case .tombstone(let recordID, let recordType):
                guard recordID == record.id, recordType == record.recordType else {
                    throw UnifiedSyncSetupError.verificationFailed
                }
                if recordType == .group {
                    groups[recordID] = nil
                } else {
                    hosts[recordID] = nil
                }
                updatedBaseline = MetadataSyncBaselinePlanner.removingEntry(
                    recordID: recordID,
                    from: updatedBaseline
                )
            }
        }

        let actions = plan.items.filter {
            $0.disposition == .uploadCreate
                || $0.disposition == .uploadUpdate
                || $0.disposition == .localDeletion
                || $0.disposition == .baselineRepair
        }.sorted {
            if $0.recordType != $1.recordType { return $0.recordType == .group }
            return $0.id.uuidString < $1.id.uuidString
        }
        for action in actions {
            let localDigest: String?
            if let group = groups[action.id], action.recordType == .group {
                localDigest = try MetadataSyncCodec.contentDigest(group: group)
            } else if let host = hosts[action.id], action.recordType == .host {
                localDigest = try MetadataSyncCodec.contentDigest(host: host)
            } else if action.disposition == .localDeletion {
                localDigest = nil
            } else {
                throw UnifiedSyncSetupError.incompatibleInventory
            }

            let saved: EncryptedSyncRecord
            if action.disposition == .baselineRepair {
                guard let remote = remoteByID[action.id] else {
                    throw UnifiedSyncSetupError.verificationFailed
                }
                saved = remote
            } else {
                let revision: UInt64
                if action.disposition == .uploadCreate {
                    revision = 1
                } else {
                    guard let oldEntry = updatedBaseline.entries.first(where: { $0.recordID == action.id }) else {
                        throw UnifiedSyncSetupError.verificationFailed
                    }
                    revision = oldEntry.remoteRevision + 1
                }
                let encrypted: EncryptedSyncRecord
                if localDigest == nil {
                    encrypted = try MetadataSyncCodec.tombstone(
                        recordID: action.id,
                        recordType: action.recordType,
                        ownerUID: ownerUID,
                        masterKey: masterKey,
                        revision: revision,
                        modifiedAt: .now,
                        modifiedByDeviceID: baseline.deviceID
                    )
                } else if let group = groups[action.id], action.recordType == .group {
                    encrypted = try MetadataSyncCodec.encrypt(
                        group: group,
                        ownerUID: ownerUID,
                        masterKey: masterKey,
                        revision: revision,
                        modifiedByDeviceID: baseline.deviceID
                    )
                } else if let host = hosts[action.id], action.recordType == .host {
                    encrypted = try MetadataSyncCodec.encrypt(
                        host: host,
                        ownerUID: ownerUID,
                        masterKey: masterKey,
                        revision: revision,
                        modifiedByDeviceID: baseline.deviceID
                    )
                } else {
                    throw UnifiedSyncSetupError.incompatibleInventory
                }
                saved = action.disposition == .uploadCreate
                    ? try await backend.create(encrypted, ownerUID: ownerUID, idToken: idToken)
                    : try await backend.upsert(encrypted, ownerUID: ownerUID, idToken: idToken)
            }
            if saved.deleted {
                updatedBaseline = MetadataSyncBaselinePlanner.removingEntry(recordID: saved.id, from: updatedBaseline)
            } else {
                guard let localDigest else { throw UnifiedSyncSetupError.verificationFailed }
                updatedBaseline = MetadataSyncBaselinePlanner.replacingEntry(
                    MetadataSyncBaselineEntry(
                        recordID: saved.id,
                        recordType: saved.recordType,
                        remoteRevision: saved.revision,
                        localContentDigest: localDigest,
                        remoteRecordDigest: try MetadataSyncCodec.encryptedRecordDigest(saved)
                    ),
                    in: updatedBaseline
                )
            }
        }

        let document = InventoryDocument(groups: Array(groups.values), hosts: Array(hosts.values))
        try MetadataMergedInventoryValidator.validate(document)
        let verifiedRemote = try await backend.fetchAll(ownerUID: ownerUID, idToken: idToken)
        let verifiedPlan = try MetadataManualSyncPlanner.makePlan(
            localGroups: document.groups,
            localHosts: document.hosts,
            remoteRecords: verifiedRemote,
            baseline: updatedBaseline,
            ownerUID: ownerUID,
            masterKey: masterKey
        )
        guard verifiedPlan.uploadCount == 0,
              verifiedPlan.downloadCount == 0,
              verifiedPlan.deletionCount == 0,
              verifiedPlan.repairCount == 0,
              verifiedPlan.conflictCount == 0,
              verifiedPlan.unchangedCount == document.groups.count + document.hosts.count else {
            throw UnifiedSyncSetupError.verificationFailed
        }
        return MetadataPreparationResult(document: document, baseline: updatedBaseline)
    }
}
