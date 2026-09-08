import Combine
import Foundation

enum AutomaticMetadataSyncStatus: Equatable {
    case disabled
    case idle
    case scheduled
    case syncing
    case waitingForConfirmation(Int)
    case paused(String)
    case failed(String)
    case cancelled

    var message: String {
        switch self {
        case .disabled: "自動同步已關閉"
        case .cancelled: "同步已取消"
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
    case unsupportedConflict
    case localChangedDuringSync
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .missingBaseline: "請先完成首次同步並建立這台 Mac 的同步基線。"
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

    private var failureOutcome: SyncAttemptOutcome?
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

    func synchronize(
        trigger: AutomaticSyncTrigger,
        hostStore: HostStore,
        settings: SyncSettingsStore,
        accountStore: CloudAccountStore,
        vaultSetupStore: VaultSetupStore
    ) async -> SyncAttemptOutcome {
        failureOutcome = nil
        guard settings.metadataSyncEnabled else {
            status = .disabled
            return .disabled
        }
        if trigger == .manual || trigger == .localChange || trigger == .confirmedRecentOverwrite {
            suppressedConfirmationID = nil
        }
        SyncDiagnosticsJournal.shared.record(.metadata, .started, trigger: trigger)
        await run(
            forceRecentOverwrite: trigger == .confirmedRecentOverwrite,
            hostStore: hostStore,
            settings: settings,
            accountStore: accountStore,
            vaultSetupStore: vaultSetupStore
        )
        if let failureOutcome { return failureOutcome }
        switch status {
        case .idle: return .completed
        case .disabled: return .disabled
        case .cancelled: return .cancelled
        case .waitingForConfirmation, .paused: return .waiting(status.message)
        default: return .retryable("同步期間資料變更，將再次同步。")
        }
    }

    func acceptPendingConfirmation() {
        pendingConfirmation = nil
        suppressedConfirmationID = nil
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
            try Task.checkCancellation()
            guard case .signedIn(let account) = accountStore.state else {
                SyncDiagnosticsJournal.shared.record(.metadata, .accountUnavailable)
                throw CloudAccountStoreError.notSignedIn
            }
            // The cloud envelope is a recovery mechanism. Once this Mac has a
            // verified local Master Key, routine metadata sync must not require
            // re-checking that envelope on every launch.
            guard case .ready = vaultSetupStore.state else {
                SyncDiagnosticsJournal.shared.record(.metadata, .vaultUnavailable)
                throw MetadataSyncPreviewError.missingMasterKey
            }
            guard let projectID = accountStore.firebaseProjectID else {
                throw CloudConfigurationError.invalidProjectID
            }
            func validateContext() throws {
                try Task.checkCancellation()
                guard settings.metadataSyncEnabled,
                      accountStore.state.signedInAccount?.uid == account.uid,
                      accountStore.firebaseProjectID == projectID else { throw CancellationError() }
            }
            guard let masterKey = try VaultMasterKeyStore.load(
                ownerUID: account.uid,
                version: VaultCryptoFormat.masterKeyVersion
            ) else {
                SyncDiagnosticsJournal.shared.record(.metadata, .keyUnavailable)
                throw MetadataSyncPreviewError.missingMasterKey
            }
            let baselineStore = MetadataSyncBaselineStore()
            guard var baseline = try baselineStore.load(ownerUID: account.uid) else {
                throw AutomaticMetadataSyncError.missingBaseline
            }
            let startingGroups = hostStore.groups
            let startingHosts = hostStore.hosts
            let token = try await accountStore.validIDToken()
            try validateContext()
            let backend = FirestoreMetadataBackend(projectID: projectID)
            SyncDiagnosticsJournal.shared.record(.metadata, .downloading)
            let snapshot = try await backend.fetchSnapshot(ownerUID: account.uid, idToken: token)
            try validateContext()
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
            let remoteByID = Dictionary(uniqueKeysWithValues: metadataRecords.map { ($0.id, $0) })
            let conflicts = plan.items.filter { $0.disposition == .conflict }
            for conflict in conflicts {
                guard let remote = remoteByID[conflict.id],
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
            let remoteApplyIDs = Set(plan.items.filter {
                $0.disposition == .download || $0.disposition == .remoteDeletion
            }.map(\.id))
            for record in metadataRecords where remoteApplyIDs.contains(record.id) {
                switch try MetadataSyncCodec.decrypt(record, ownerUID: account.uid, masterKey: masterKey) {
                case .group(let group):
                    groups[group.id] = group
                    baseline = MetadataSyncBaselinePlanner.replacingEntry(
                        MetadataSyncBaselineEntry(
                            recordID: record.id,
                            recordType: record.recordType,
                            remoteRevision: record.revision,
                            localContentDigest: try MetadataSyncCodec.contentDigest(group: group),
                            remoteRecordDigest: try MetadataSyncCodec.encryptedRecordDigest(record)
                        ),
                        in: baseline
                    )
                case .host(var host):
                    if host.authenticationMethod == .privateKey,
                       let path = hosts[host.id]?.privateKeyPath,
                       !path.isEmpty {
                        host.privateKeyPath = path
                    }
                    hosts[host.id] = host
                    baseline = MetadataSyncBaselinePlanner.replacingEntry(
                        MetadataSyncBaselineEntry(
                            recordID: record.id,
                            recordType: record.recordType,
                            remoteRevision: record.revision,
                            localContentDigest: try MetadataSyncCodec.contentDigest(host: host),
                            remoteRecordDigest: try MetadataSyncCodec.encryptedRecordDigest(record)
                        ),
                        in: baseline
                    )
                case .tombstone(let recordID, let recordType):
                    guard recordID == record.id, recordType == record.recordType else {
                        throw AutomaticMetadataSyncError.verificationFailed
                    }
                    if recordType == .group {
                        groups[recordID] = nil
                    } else {
                        hosts[recordID] = nil
                    }
                    baseline = MetadataSyncBaselinePlanner.removingEntry(recordID: recordID, from: baseline)
                }
            }

            let actionItems = plan.items.filter {
                $0.disposition == .uploadCreate
                    || $0.disposition == .uploadUpdate
                    || $0.disposition == .localDeletion
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
                let localDigest: String?
                if let group = groups[action.id], action.recordType == .group {
                    localDigest = try MetadataSyncCodec.contentDigest(group: group)
                } else if let host = hosts[action.id], action.recordType == .host {
                    localDigest = try MetadataSyncCodec.contentDigest(host: host)
                } else if action.disposition == .localDeletion || action.disposition == .conflict {
                    localDigest = nil
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
                    if localDigest == nil {
                        guard action.disposition == .localDeletion || action.disposition == .conflict else {
                            throw AutomaticMetadataSyncError.unsupportedConflict
                        }
                        pending = try MetadataSyncCodec.tombstone(
                            recordID: action.id,
                            recordType: action.recordType,
                            ownerUID: account.uid,
                            masterKey: masterKey,
                            revision: revision,
                            modifiedAt: .now,
                            modifiedByDeviceID: baseline.deviceID
                        )
                    } else if let group = groups[action.id], action.recordType == .group {
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
                try validateContext()
                if saved.deleted {
                    baseline = MetadataSyncBaselinePlanner.removingEntry(recordID: saved.id, from: baseline)
                } else {
                    guard let localDigest else { throw AutomaticMetadataSyncError.verificationFailed }
                    let entry = MetadataSyncBaselineEntry(
                        recordID: saved.id,
                        recordType: saved.recordType,
                        remoteRevision: saved.revision,
                        localContentDigest: localDigest,
                        remoteRecordDigest: try MetadataSyncCodec.encryptedRecordDigest(saved)
                    )
                    baseline = MetadataSyncBaselinePlanner.replacingEntry(entry, in: baseline)
                }
                try baselineStore.save(baseline, ownerUID: account.uid)
            }

            let finalDocument = InventoryDocument(
                groups: Array(groups.values),
                hosts: Array(hosts.values)
            )
            try MetadataMergedInventoryValidator.validate(finalDocument)
            let verifiedRemote = try await backend.fetchAll(ownerUID: account.uid, idToken: token)
            try validateContext()
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
                  verifiedPlan.deletionCount == 0,
                  verifiedPlan.repairCount == 0,
                  verifiedPlan.conflictCount == 0,
                  verifiedPlan.unchangedCount == finalDocument.groups.count + finalDocument.hosts.count else {
                throw AutomaticMetadataSyncError.verificationFailed
            }
            guard hostStore.groups == startingGroups, hostStore.hosts == startingHosts else {
                throw AutomaticMetadataSyncError.localChangedDuringSync
            }
            if !remoteApplyIDs.isEmpty {
                isApplyingRemoteChanges = true
                defer { isApplyingRemoteChanges = false }
                _ = try hostStore.applyVerifiedCloudMerge(finalDocument)
            }
            try baselineStore.save(baseline, ownerUID: account.uid)

            let passwordSnapshot = try await backend.fetchSnapshot(ownerUID: account.uid, idToken: token)
            try validateContext()
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
            try validateContext()
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
            SyncDiagnosticsJournal.shared.record(.metadata, .completed)
        } catch is CancellationError {
            status = .cancelled
            SyncDiagnosticsJournal.shared.record(.metadata, .cancelled)
        } catch AutomaticMetadataSyncError.localChangedDuringSync {
            status = .scheduled
        } catch {
            let outcome: SyncAttemptOutcome
            if case MetadataSyncPreviewError.missingMasterKey = error {
                outcome = .waiting("同步保管庫尚未就緒，請檢查帳號與同步密語設定。")
            } else if case CloudAccountStoreError.notSignedIn = error {
                outcome = .waiting("等待 Google 登入恢復。")
            } else if case AutomaticMetadataSyncError.missingBaseline = error {
                outcome = .waiting("請先完成首次同步並建立這台 Mac 的同步基線。")
            } else if case FirestoreMetadataBackendError.serverFailure(let code) = error, code >= 500 || code == 429 {
                outcome = .retryable("雲端服務暫時無法完成主機同步，將自動重試。")
            } else {
                outcome = .failure(error)
            }
            failureOutcome = outcome
            status = .failed(outcome.message)
            SyncDiagnosticsJournal.shared.record(.metadata, .failed, error: error)
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
                digest = "deleted:\(item.recordType):\(item.id.uuidString.lowercased())"
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
