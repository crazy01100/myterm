import Combine
import Foundation

enum AutomaticConnectionAuditSyncStatus: Equatable {
    case disabled
    case idle
    case scheduled
    case syncing
    case failed(String)
    case cancelled

    var message: String {
        switch self {
        case .disabled: "未啟用"
        case .cancelled: "同步已取消"
        case .idle: "同步完成"
        case .scheduled: "已排入同步"
        case .syncing: "正在同步"
        case .failed(let message): message
        }
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}

@MainActor
final class AutomaticConnectionAuditSyncStore: ObservableObject {
    @Published private(set) var status: AutomaticConnectionAuditSyncStatus = .disabled
    @Published private(set) var lastSuccessfulSyncAt: Date?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func updateAvailability(settings: SyncSettingsStore, accountStore: CloudAccountStore) {
        if let uid = accountStore.state.signedInAccount?.uid {
            lastSuccessfulSyncAt = defaults.object(forKey: successKey(uid)) as? Date
        } else {
            lastSuccessfulSyncAt = nil
        }
        if !settings.metadataSyncEnabled { status = .disabled }
    }

    private func successKey(_ uid: String) -> String {
        "cloudSync.logs.lastSuccess.v1." + MetadataSyncBaselineStore.ownerDigest(uid)
    }

    func synchronize(
        trigger: AutomaticSyncTrigger,
        auditStore: ConnectionAuditStore,
        settings: SyncSettingsStore,
        accountStore: CloudAccountStore,
        vaultSetupStore: VaultSetupStore
    ) async -> SyncAttemptOutcome {
        auditStore.performRetentionMaintenance()
        guard settings.metadataSyncEnabled else {
            status = .disabled
            return .disabled
        }
        SyncDiagnosticsJournal.shared.record(.logs, .started, trigger: trigger)
        status = .syncing
        do {
            try Task.checkCancellation()
            guard case .signedIn(let account) = accountStore.state else {
                SyncDiagnosticsJournal.shared.record(.logs, .accountUnavailable)
                throw CloudAccountStoreError.notSignedIn
            }
            guard case .ready = vaultSetupStore.state else {
                SyncDiagnosticsJournal.shared.record(.logs, .vaultUnavailable)
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
                SyncDiagnosticsJournal.shared.record(.logs, .keyUnavailable)
                throw MetadataSyncPreviewError.missingMasterKey
            }
            let idToken = try await accountStore.validIDToken()
            try validateContext()
            let backend = FirestoreConnectionAuditBackend(projectID: projectID)
            SyncDiagnosticsJournal.shared.record(.logs, .downloading)
            let snapshot = try await backend.fetchSnapshot(ownerUID: account.uid, idToken: idToken)
            try validateContext()
            SyncDiagnosticsJournal.shared.record(.logs, .downloaded, count: snapshot.records.count)
            guard let referenceDate = snapshot.serverDate else {
                throw FirestoreConnectionAuditBackendError.invalidResponse
            }
            let cutoff = referenceDate.addingTimeInterval(-ConnectionAuditStore.retentionInterval)

            var retainedRemote: [ConnectionAuditRecord] = []
            var expiredRemoteIDs: [UUID] = []
            for encrypted in snapshot.records {
                let record = try ConnectionAuditSyncCodec.decrypt(
                    encrypted,
                    ownerUID: account.uid,
                    masterKey: masterKey
                )
                if record.retentionReferenceDate < cutoff {
                    expiredRemoteIDs.append(record.id)
                } else {
                    retainedRemote.append(record)
                }
            }

            SyncDiagnosticsJournal.shared.record(.logs, .merging, count: retainedRemote.count)
            auditStore.mergeFinalizedFromSync(retainedRemote, referenceDate: referenceDate)
            let remoteIDs = Set(retainedRemote.map(\.id))
            let localRecords = auditStore.finalizedRecordsForSync(referenceDate: referenceDate)
            SyncDiagnosticsJournal.shared.record(.logs, .uploading, count: localRecords.filter { !remoteIDs.contains($0.id) }.count)
            for record in localRecords where !remoteIDs.contains(record.id) {
                try validateContext()
                let encrypted = try ConnectionAuditSyncCodec.encrypt(
                    record,
                    ownerUID: account.uid,
                    masterKey: masterKey
                )
                do {
                    _ = try await backend.create(
                        encrypted,
                        ownerUID: account.uid,
                        idToken: idToken
                    )
                } catch FirestoreConnectionAuditBackendError.documentAlreadyExists {
                    // A retry or another device already created the same immutable UUID.
                }
            }
            for recordID in expiredRemoteIDs {
                try validateContext()
                try await backend.delete(
                    recordID: recordID,
                    ownerUID: account.uid,
                    idToken: idToken
                )
            }
            try validateContext()
            SyncDiagnosticsJournal.shared.record(.logs, .saving)
            try await auditStore.persistForSync()
            try validateContext()
            lastSuccessfulSyncAt = referenceDate
            defaults.set(referenceDate, forKey: successKey(account.uid))
            status = .idle
            SyncDiagnosticsJournal.shared.record(.logs, .completed)
            return .completed
        } catch is CancellationError {
            status = .cancelled
            SyncDiagnosticsJournal.shared.record(.logs, .cancelled)
            return .cancelled
        } catch {
            let outcome: SyncAttemptOutcome
            if case MetadataSyncPreviewError.missingMasterKey = error {
                outcome = .waiting("同步保管庫尚未就緒，請檢查帳號與同步密語設定。")
            } else if case CloudAccountStoreError.notSignedIn = error {
                outcome = .waiting("等待 Google 登入恢復。")
            } else if case FirestoreConnectionAuditBackendError.serverFailure(let code) = error, code >= 500 || code == 429 {
                outcome = .retryable("雲端服務暫時無法完成 Logs 同步，將自動重試。")
            } else {
                outcome = .failure(error)
            }
            status = .failed(outcome.message)
            SyncDiagnosticsJournal.shared.record(.logs, .failed, error: error)
            return outcome
        }
    }
}
