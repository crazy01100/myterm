import Combine
import Foundation

enum AutomaticMetadataSyncTrigger: Equatable, Sendable {
    case launch
    case foreground
    case periodic
    case localChange
    case manual
    case confirmedRecentOverwrite
}

enum AutomaticMetadataSyncStatus: Equatable {
    case disabled
    case idle
    case scheduled
    case syncing
    case waitingForConfirmation(Int)
    case paused(String)
    case failed(String)

    var message: String {
        switch self {
        case .disabled: "自動同步已關閉"
        case .idle: "同步就緒"
        case .scheduled: "已排入同步"
        case .syncing: "正在進行端對端加密同步…"
        case .waitingForConfirmation(let count): "有 \(count) 筆近期跨裝置變更，等待確認"
        case .paused(let message), .failed(let message): message
        }
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct PendingRecentSyncConfirmation: Identifiable, Equatable {
    let id: String
    let recordNames: [String]

    var title: String {
        recordNames.count == 1 ? recordNames[0] : "\(recordNames.count) 筆同步資料"
    }
}

enum AutomaticMetadataSyncError: LocalizedError, Equatable {
    case missingBaseline
    case unsafeDeletion
    case unsupportedConflict
    case localChangedDuringSync
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .missingBaseline: "請先完成首次同步並建立這台 Mac 的同步基線。"
        case .unsafeDeletion: "偵測到刪除或刪除後編輯；為避免誤刪，已停止自動同步。"
        case .unsupportedConflict: "同步資料的類型或階層不一致；已停止自動同步。"
        case .localChangedDuringSync: "同步期間本機資料再次變更，稍後會用最新版重新同步。"
        case .verificationFailed: "同步後回讀驗證未通過，沒有套用下載內容。"
        }
    }
}

@MainActor
final class AutomaticMetadataSyncStore: ObservableObject {
    static let lastSuccessKeyPrefix = "cloudSync.metadata.lastSuccess.v1."

    @Published private(set) var status: AutomaticMetadataSyncStatus = .disabled
    @Published private(set) var lastSuccessfulSyncAt: Date?
    @Published private(set) var pendingConfirmation: PendingRecentSyncConfirmation?
    @Published private(set) var isApplyingRemoteChanges = false

    private var operationTask: Task<Void, Never>?
    private var needsAnotherPass = false
    private var suppressedConfirmationID: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func updateAvailability(
        settings: SyncSettingsStore,
        accountStore: CloudAccountStore
    ) {
        settings.setContext(
            availability: accountStore.firebaseProjectID == nil ? .notConfigured : .ready,
            ownerUID: accountStore.state.signedInAccount?.uid
        )
        if !settings.metadataSyncEnabled {
            status = .disabled
            pendingConfirmation = nil
        }
        restoreLastSuccess(for: accountStore.state.signedInAccount?.uid)
    }

    func localInventoryDidChange(
        hostStore: HostStore,
        settings: SyncSettingsStore,
        accountStore: CloudAccountStore,
        vaultSetupStore: VaultSetupStore
    ) {
        suppressedConfirmationID = nil
        request(
            trigger: .localChange,
            hostStore: hostStore,
            settings: settings,
            accountStore: accountStore,
            vaultSetupStore: vaultSetupStore
        )
    }

    func request(
        trigger: AutomaticMetadataSyncTrigger,
        hostStore: HostStore,
        settings: SyncSettingsStore,
        accountStore: CloudAccountStore,
        vaultSetupStore: VaultSetupStore
    ) {
        guard settings.metadataSyncEnabled else {
            status = .disabled
            return
        }
        if trigger == .manual {
            suppressedConfirmationID = nil
        }
        guard operationTask == nil else {
            needsAnotherPass = true
            return
        }
        status = trigger == .localChange ? .scheduled : .syncing
        operationTask = Task { [weak self, weak hostStore, weak settings, weak accountStore, weak vaultSetupStore] in
            guard let self, let hostStore, let settings, let accountStore, let vaultSetupStore else { return }
            if trigger == .localChange {
                try? await Task.sleep(for: .seconds(1.2))
            }
            guard !Task.isCancelled else { return }
            await self.run(
                forceRecentOverwrite: trigger == .confirmedRecentOverwrite,
                hostStore: hostStore,
                settings: settings,
                accountStore: accountStore,
                vaultSetupStore: vaultSetupStore
            )
            self.operationTask = nil
            if self.needsAnotherPass {
                self.needsAnotherPass = false
                self.request(
                    trigger: .foreground,
                    hostStore: hostStore,
                    settings: settings,
                    accountStore: accountStore,
                    vaultSetupStore: vaultSetupStore
                )
            }
        }
    }

    func confirmRecentUpdate(
        hostStore: HostStore,
        settings: SyncSettingsStore,
        accountStore: CloudAccountStore,
        vaultSetupStore: VaultSetupStore
    ) {
        pendingConfirmation = nil
        suppressedConfirmationID = nil
        request(
            trigger: .confirmedRecentOverwrite,
            hostStore: hostStore,
            settings: settings,
            accountStore: accountStore,
            vaultSetupStore: vaultSetupStore
        )
    }

    func declineRecentUpdate() {
        if let pendingConfirmation {
            suppressedConfirmationID = pendingConfirmation.id
        }
        pendingConfirmation = nil
        status = .paused("已選擇不更新；這台 Mac 的變更尚未同步。")
    }

    private func run(
        forceRecentOverwrite: Bool,
        hostStore: HostStore,
        settings: SyncSettingsStore,
        accountStore: CloudAccountStore,
        vaultSetupStore: VaultSetupStore
    ) async {
        guard settings.metadataSyncEnabled else {
            status = .disabled
            return
        }
        status = .syncing
        do {
            guard case .signedIn(let account) = accountStore.state else {
                throw CloudAccountStoreError.notSignedIn
            }
            // The cloud envelope is a recovery mechanism. Once this Mac has a
            // verified local Master Key, routine metadata sync must not require
            // re-checking that envelope on every launch.
            guard case .ready = vaultSetupStore.state else {
                throw MetadataSyncPreviewError.missingMasterKey
            }
            guard let projectID = accountStore.firebaseProjectID else {
                throw CloudConfigurationError.invalidProjectID
            }
            guard let masterKey = try VaultMasterKeyStore.load(
                ownerUID: account.uid,
                version: VaultCryptoFormat.masterKeyVersion
            ) else {
                throw MetadataSyncPreviewError.missingMasterKey
            }
            let baselineStore = MetadataSyncBaselineStore()
            guard var baseline = try baselineStore.load(ownerUID: account.uid) else {
                throw AutomaticMetadataSyncError.missingBaseline
            }
            let startingGroups = hostStore.groups
            let startingHosts = hostStore.hosts
            let token = try await accountStore.validIDToken()
            let backend = FirestoreMetadataBackend(projectID: projectID)
            let snapshot = try await backend.fetchSnapshot(ownerUID: account.uid, idToken: token)
            let metadataRecords = snapshot.records.filter {
                $0.recordType == .host || $0.recordType == .group
            }
            let plan = try MetadataManualSyncPlanner.makePlan(
                localGroups: startingGroups,
                localHosts: startingHosts,
                remoteRecords: metadataRecords,
                baseline: baseline,
                ownerUID: account.uid,
                masterKey: masterKey
            )
            guard plan.deletionCount == 0 else { throw AutomaticMetadataSyncError.unsafeDeletion }

            let remoteByID = Dictionary(uniqueKeysWithValues: metadataRecords.map { ($0.id, $0) })
            let conflicts = plan.items.filter { $0.disposition == .conflict }
            for conflict in conflicts {
                guard let remote = remoteByID[conflict.id],
                      !remote.deleted,
                      remote.recordType == conflict.recordType else {
                    throw AutomaticMetadataSyncError.unsupportedConflict
                }
            }
            let recentConflicts = conflicts.filter {
                RecentCloudUpdatePolicy.requiresConfirmation(
                    updateTime: snapshot.updateTimes[$0.id],
                    serverDate: snapshot.serverDate
                )
            }
            if !recentConflicts.isEmpty && !forceRecentOverwrite {
                let confirmation = try makeConfirmation(
                    items: recentConflicts,
                    remoteByID: remoteByID,
                    localGroups: startingGroups,
                    localHosts: startingHosts
                )
                if suppressedConfirmationID == confirmation.id {
                    status = .paused("已選擇不更新；這台 Mac 的變更尚未同步。")
                    return
                }
                pendingConfirmation = confirmation
                status = .waitingForConfirmation(confirmation.recordNames.count)
                return
            }

            guard hostStore.groups == startingGroups, hostStore.hosts == startingHosts else {
                throw AutomaticMetadataSyncError.localChangedDuringSync
            }
            var groups = Dictionary(uniqueKeysWithValues: startingGroups.map { ($0.id, $0) })
            var hosts = Dictionary(uniqueKeysWithValues: startingHosts.map { ($0.id, $0) })
            let downloadIDs = Set(plan.items.filter { $0.disposition == .download }.map(\.id))
            for record in metadataRecords where downloadIDs.contains(record.id) {
                let localDigest: String
                switch try MetadataSyncCodec.decrypt(record, ownerUID: account.uid, masterKey: masterKey) {
                case .group(let group):
                    groups[group.id] = group
                    localDigest = try MetadataSyncCodec.contentDigest(group: group)
                case .host(var host):
                    if host.authenticationMethod == .privateKey,
                       let path = hosts[host.id]?.privateKeyPath,
                       !path.isEmpty {
                        host.privateKeyPath = path
                    }
                    hosts[host.id] = host
                    localDigest = try MetadataSyncCodec.contentDigest(host: host)
                case .tombstone:
                    throw AutomaticMetadataSyncError.unsafeDeletion
                }
                baseline = MetadataSyncBaselinePlanner.replacingEntry(
                    MetadataSyncBaselineEntry(
                        recordID: record.id,
                        recordType: record.recordType,
                        remoteRevision: record.revision,
                        localContentDigest: localDigest,
                        remoteRecordDigest: try MetadataSyncCodec.encryptedRecordDigest(record)
                    ),
                    in: baseline
                )
            }

            let actionItems = plan.items.filter {
                $0.disposition == .uploadCreate
                    || $0.disposition == .uploadUpdate
                    || $0.disposition == .baselineRepair
                    || $0.disposition == .conflict
            }.sorted {
                if $0.recordType != $1.recordType { return $0.recordType == .group }
                return $0.id.uuidString < $1.id.uuidString
            }
            for action in actionItems {
                guard hostStore.groups == startingGroups, hostStore.hosts == startingHosts else {
                    throw AutomaticMetadataSyncError.localChangedDuringSync
                }
                let localDigest: String
                if let group = groups[action.id], action.recordType == .group {
                    localDigest = try MetadataSyncCodec.contentDigest(group: group)
                } else if let host = hosts[action.id], action.recordType == .host {
                    localDigest = try MetadataSyncCodec.contentDigest(host: host)
                } else {
                    throw AutomaticMetadataSyncError.unsupportedConflict
                }

                let saved: EncryptedSyncRecord
                if action.disposition == .baselineRepair {
                    guard let remote = remoteByID[action.id] else {
                        throw AutomaticMetadataSyncError.verificationFailed
                    }
                    saved = remote
                } else {
                    let revision: UInt64
                    if action.disposition == .uploadCreate {
                        revision = 1
                    } else if action.disposition == .conflict {
                        guard let remote = remoteByID[action.id] else {
                            throw AutomaticMetadataSyncError.unsupportedConflict
                        }
                        revision = remote.revision + 1
                    } else {
                        guard let entry = baseline.entries.first(where: { $0.recordID == action.id }) else {
                            throw MetadataManualSyncError.invalidBaseline
                        }
                        revision = entry.remoteRevision + 1
                    }
                    let pending: EncryptedSyncRecord
                    if let group = groups[action.id], action.recordType == .group {
                        pending = try MetadataSyncCodec.encrypt(
                            group: group,
                            ownerUID: account.uid,
                            masterKey: masterKey,
                            revision: revision,
                            modifiedByDeviceID: baseline.deviceID
                        )
                    } else if let host = hosts[action.id], action.recordType == .host {
                        pending = try MetadataSyncCodec.encrypt(
                            host: host,
                            ownerUID: account.uid,
                            masterKey: masterKey,
                            revision: revision,
                            modifiedByDeviceID: baseline.deviceID
                        )
                    } else {
                        throw AutomaticMetadataSyncError.unsupportedConflict
                    }
                    saved = action.disposition == .uploadCreate
                        ? try await backend.create(pending, ownerUID: account.uid, idToken: token)
                        : try await backend.upsert(pending, ownerUID: account.uid, idToken: token)
                }
                let entry = MetadataSyncBaselineEntry(
                    recordID: saved.id,
                    recordType: saved.recordType,
                    remoteRevision: saved.revision,
                    localContentDigest: localDigest,
                    remoteRecordDigest: try MetadataSyncCodec.encryptedRecordDigest(saved)
                )
                baseline = MetadataSyncBaselinePlanner.replacingEntry(entry, in: baseline)
                try baselineStore.save(baseline, ownerUID: account.uid)
            }

            let finalDocument = InventoryDocument(
                groups: Array(groups.values),
                hosts: Array(hosts.values)
            )
            try MetadataMergedInventoryValidator.validate(finalDocument)
            let verifiedRemote = try await backend.fetchAll(ownerUID: account.uid, idToken: token)
            let verifiedPlan = try MetadataManualSyncPlanner.makePlan(
                localGroups: finalDocument.groups,
                localHosts: finalDocument.hosts,
                remoteRecords: verifiedRemote,
                baseline: baseline,
                ownerUID: account.uid,
                masterKey: masterKey
            )
            guard verifiedPlan.uploadCount == 0,
                  verifiedPlan.downloadCount == 0,
                  verifiedPlan.repairCount == 0,
                  verifiedPlan.conflictCount == 0,
                  verifiedPlan.unchangedCount == finalDocument.groups.count + finalDocument.hosts.count else {
                throw AutomaticMetadataSyncError.verificationFailed
            }
            guard hostStore.groups == startingGroups, hostStore.hosts == startingHosts else {
                throw AutomaticMetadataSyncError.localChangedDuringSync
            }
            if !downloadIDs.isEmpty {
                isApplyingRemoteChanges = true
                defer { isApplyingRemoteChanges = false }
                _ = try hostStore.applyVerifiedCloudMerge(finalDocument)
            }
            try baselineStore.save(baseline, ownerUID: account.uid)

            let passwordSnapshot = try await backend.fetchSnapshot(ownerUID: account.uid, idToken: token)
            let passwordOutcome = try await PasswordSyncService().synchronize(
                hosts: finalDocument.hosts,
                snapshot: passwordSnapshot,
                backend: backend,
                ownerUID: account.uid,
                idToken: token,
                masterKey: masterKey,
                deviceID: baseline.deviceID,
                forceRecentOverwrite: forceRecentOverwrite
            )
            if case .needsRecentOverwriteConfirmation(let pending) = passwordOutcome {
                let confirmation = PendingRecentSyncConfirmation(
                    id: pending.signature,
                    recordNames: pending.names.map { "\($0) 的密碼" }
                )
                if suppressedConfirmationID == confirmation.id {
                    status = .paused("已選擇不更新；這台 Mac 的密碼變更尚未同步。")
                    return
                }
                pendingConfirmation = confirmation
                status = .waitingForConfirmation(confirmation.recordNames.count)
                return
            }
            pendingConfirmation = nil
            suppressedConfirmationID = nil
            let completedAt = Date()
            lastSuccessfulSyncAt = completedAt
            defaults.set(completedAt, forKey: lastSuccessKey(for: account.uid))
            status = .idle
        } catch is CancellationError {
            status = settings.metadataSyncEnabled ? .idle : .disabled
        } catch AutomaticMetadataSyncError.localChangedDuringSync {
            status = .scheduled
            needsAnotherPass = true
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func makeConfirmation(
        items: [MetadataManualSyncItem],
        remoteByID: [UUID: EncryptedSyncRecord],
        localGroups: [HostGroup],
        localHosts: [HostProfile]
    ) throws -> PendingRecentSyncConfirmation {
        let groupByID = Dictionary(uniqueKeysWithValues: localGroups.map { ($0.id, $0) })
        let hostByID = Dictionary(uniqueKeysWithValues: localHosts.map { ($0.id, $0) })
        var signatureParts: [String] = []
        for item in items.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let remote = remoteByID[item.id] else {
                throw AutomaticMetadataSyncError.unsupportedConflict
            }
            let digest: String
            if let group = groupByID[item.id] {
                digest = try MetadataSyncCodec.contentDigest(group: group)
            } else if let host = hostByID[item.id] {
                digest = try MetadataSyncCodec.contentDigest(host: host)
            } else {
                throw AutomaticMetadataSyncError.unsupportedConflict
            }
            signatureParts.append("\(item.id.uuidString):\(remote.revision):\(digest)")
        }
        return PendingRecentSyncConfirmation(
            id: signatureParts.joined(separator: "|"),
            recordNames: items.map(\.displayName).sorted()
        )
    }

    private func restoreLastSuccess(for ownerUID: String?) {
        guard let ownerUID else {
            lastSuccessfulSyncAt = nil
            return
        }
        lastSuccessfulSyncAt = defaults.object(forKey: lastSuccessKey(for: ownerUID)) as? Date
    }

    private func lastSuccessKey(for ownerUID: String) -> String {
        Self.lastSuccessKeyPrefix + MetadataSyncBaselineStore.ownerDigest(ownerUID)
    }
}

private extension CloudAccountState {
    var signedInAccount: FirebaseAccount? {
        guard case .signedIn(let account) = self else { return nil }
        return account
    }
}
