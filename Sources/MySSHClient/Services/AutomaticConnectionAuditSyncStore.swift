import Combine
import Foundation

enum AutomaticConnectionAuditSyncTrigger: Equatable, Sendable {
    case launch
    case foreground
    case periodic
    case localFinalized
    case manual
}

enum AutomaticConnectionAuditSyncStatus: Equatable {
    case disabled
    case idle
    case scheduled
    case syncing
    case failed(String)

    var message: String {
        switch self {
        case .disabled: "未啟用"
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

    private var operationTask: Task<Void, Never>?
    private var needsAnotherPass = false
    private var lastPeriodicAttemptAt: Date?

    func request(
        trigger: AutomaticConnectionAuditSyncTrigger,
        auditStore: ConnectionAuditStore,
        settings: SyncSettingsStore,
        accountStore: CloudAccountStore,
        vaultSetupStore: VaultSetupStore
    ) {
        auditStore.performRetentionMaintenance()
        guard settings.metadataSyncEnabled else {
            status = .disabled
            return
        }
        if trigger == .periodic,
           let lastPeriodicAttemptAt,
           Date().timeIntervalSince(lastPeriodicAttemptAt) < 15 * 60 {
            return
        }
        if trigger == .periodic { lastPeriodicAttemptAt = Date() }
        guard operationTask == nil else {
            needsAnotherPass = true
            return
        }
        status = trigger == .localFinalized ? .scheduled : .syncing
        operationTask = Task { [weak self, weak auditStore, weak settings, weak accountStore, weak vaultSetupStore] in
            guard let self, let auditStore, let settings, let accountStore, let vaultSetupStore else {
                return
            }
            if trigger == .localFinalized {
                try? await Task.sleep(for: .seconds(1.2))
            }
            guard !Task.isCancelled else { return }
            await self.run(
                auditStore: auditStore,
                settings: settings,
                accountStore: accountStore,
                vaultSetupStore: vaultSetupStore
            )
            self.operationTask = nil
            if self.needsAnotherPass {
                self.needsAnotherPass = false
                self.request(
                    trigger: .foreground,
                    auditStore: auditStore,
                    settings: settings,
                    accountStore: accountStore,
                    vaultSetupStore: vaultSetupStore
                )
            }
        }
    }

    private func run(
        auditStore: ConnectionAuditStore,
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
            let idToken = try await accountStore.validIDToken()
            let backend = FirestoreConnectionAuditBackend(projectID: projectID)
            let snapshot = try await backend.fetchSnapshot(ownerUID: account.uid, idToken: idToken)
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

            auditStore.mergeFinalizedFromSync(retainedRemote, referenceDate: referenceDate)
            let remoteIDs = Set(retainedRemote.map(\.id))
            let localRecords = auditStore.finalizedRecordsForSync(referenceDate: referenceDate)
            for record in localRecords where !remoteIDs.contains(record.id) {
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
                try await backend.delete(
                    recordID: recordID,
                    ownerUID: account.uid,
                    idToken: idToken
                )
            }
            lastSuccessfulSyncAt = referenceDate
            status = .idle
        } catch is CancellationError {
            status = settings.metadataSyncEnabled ? .idle : .disabled
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
