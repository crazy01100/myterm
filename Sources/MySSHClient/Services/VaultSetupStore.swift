import Combine
import Foundation

enum VaultSetupState: Equatable {
    case signedOut
    case notCreated
    case working(String)
    case awaitingRecoveryKey(String, LocalVaultSummary)
    case recoveryConfirmationRequired(LocalVaultSummary)
    case ready(LocalVaultSummary)
    case missingLocalMasterKey(LocalVaultSummary)
    case failed(String)
}

enum VaultCloudEnvelopeState: Equatable {
    case notChecked
    case checking
    case notFound
    case available
    case uploading
    case conflict
    case failed(String)
}

@MainActor
final class VaultSetupStore: ObservableObject {
    @Published private(set) var state: VaultSetupState = .signedOut
    @Published private(set) var cloudEnvelopeState: VaultCloudEnvelopeState = .notChecked

    private let envelopeStore: VaultEnvelopeStore
    private var currentOwnerUID: String?
    private var operationTask: Task<Void, Never>?

    init(envelopeStore: VaultEnvelopeStore = VaultEnvelopeStore()) {
        self.envelopeStore = envelopeStore
    }

    func refresh(account: FirebaseAccount?) {
        operationTask?.cancel()
        operationTask = nil
        if currentOwnerUID != account?.uid {
            cloudEnvelopeState = .notChecked
        }
        currentOwnerUID = account?.uid
        guard let account else {
            state = .signedOut
            return
        }
        do {
            guard let summary = try VaultSetupService.summary(
                ownerUID: account.uid,
                envelopeStore: envelopeStore
            ) else {
                state = .notCreated
                return
            }
            let masterKey = try VaultMasterKeyStore.load(ownerUID: account.uid, version: summary.keyVersion)
            if masterKey == nil {
                state = .missingLocalMasterKey(summary)
            } else if summary.recoveryConfirmed {
                state = .ready(summary)
            } else {
                state = .recoveryConfirmationRequired(summary)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func create(passphrase: String) {
        guard operationTask == nil, let ownerUID = currentOwnerUID else { return }
        state = .working("正在建立端對端加密保管庫…")
        let envelopeStore = envelopeStore
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let creation = try await Task.detached(priority: .userInitiated) {
                    try VaultSetupService.create(
                        ownerUID: ownerUID,
                        passphrase: passphrase,
                        envelopeStore: envelopeStore
                    )
                }.value
                guard self.currentOwnerUID == ownerUID else { return }
                self.state = .awaitingRecoveryKey(
                    creation.recoveryKey,
                    Self.summary(for: creation.document)
                )
            } catch is CancellationError {
                self.refresh(account: nil)
            } catch {
                self.state = .failed(error.localizedDescription)
            }
            self.operationTask = nil
        }
    }

    func replaceUnconfirmedRecoveryKey() {
        guard operationTask == nil, let ownerUID = currentOwnerUID else { return }
        state = .working("正在產生新的復原金鑰…")
        let envelopeStore = envelopeStore
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let creation = try await Task.detached(priority: .userInitiated) {
                    try VaultSetupService.replaceUnconfirmedRecoveryKey(
                        ownerUID: ownerUID,
                        envelopeStore: envelopeStore
                    )
                }.value
                guard self.currentOwnerUID == ownerUID else { return }
                self.state = .awaitingRecoveryKey(
                    creation.recoveryKey,
                    Self.summary(for: creation.document)
                )
            } catch {
                self.state = .failed(error.localizedDescription)
            }
            self.operationTask = nil
        }
    }

    func confirmRecoveryKeySaved() {
        guard let ownerUID = currentOwnerUID else { return }
        do {
            let document = try VaultSetupService.confirmRecoveryKey(
                ownerUID: ownerUID,
                envelopeStore: envelopeStore
            )
            state = .ready(Self.summary(for: document))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func discardDisplayedRecoveryKey() {
        guard case .awaitingRecoveryKey(_, let summary) = state else { return }
        state = .recoveryConfirmationRequired(summary)
    }

    func restoreWithPassphrase(_ passphrase: String) {
        restore(using: .passphrase(passphrase))
    }

    func restoreWithRecoveryKey(_ recoveryKey: String) {
        restore(using: .recoveryKey(recoveryKey))
    }

    func checkCloudEnvelope(projectID: String, idToken: String) async {
        guard let ownerUID = currentOwnerUID,
              cloudEnvelopeState != .checking,
              cloudEnvelopeState != .uploading else { return }
        cloudEnvelopeState = .checking
        do {
            let backend = FirestoreVaultBackend(projectID: projectID)
            guard let remoteDocument = try await backend.fetchEnvelope(
                ownerUID: ownerUID,
                idToken: idToken
            ) else {
                cloudEnvelopeState = .notFound
                return
            }
            guard currentOwnerUID == ownerUID else { return }
            if let localDocument = try envelopeStore.load(ownerUID: ownerUID) {
                guard localDocument == remoteDocument else {
                    cloudEnvelopeState = .conflict
                    return
                }
            } else {
                try envelopeStore.save(remoteDocument)
            }
            cloudEnvelopeState = .available
            refreshCurrentOwner()
        } catch {
            cloudEnvelopeState = .failed(error.localizedDescription)
        }
    }

    func uploadCloudEnvelope(projectID: String, idToken: String) async {
        guard let ownerUID = currentOwnerUID,
              cloudEnvelopeState == .notFound else { return }
        cloudEnvelopeState = .uploading
        do {
            guard let document = try envelopeStore.load(ownerUID: ownerUID),
                  document.recoveryConfirmedAt != nil else {
                throw VaultSetupError.notFound
            }
            let backend = FirestoreVaultBackend(projectID: projectID)
            try await backend.upsertEnvelope(document, ownerUID: ownerUID, idToken: idToken)
            guard currentOwnerUID == ownerUID else { return }
            cloudEnvelopeState = .available
        } catch {
            cloudEnvelopeState = .failed(error.localizedDescription)
        }
    }

    func retryCloudCheck() {
        cloudEnvelopeState = .notChecked
    }

    func retry() {
        guard let ownerUID = currentOwnerUID else {
            state = .signedOut
            return
        }
        refresh(account: FirebaseAccount(uid: ownerUID, email: nil, displayName: nil))
    }

    private func refreshCurrentOwner() {
        guard let ownerUID = currentOwnerUID else {
            state = .signedOut
            return
        }
        do {
            guard let summary = try VaultSetupService.summary(
                ownerUID: ownerUID,
                envelopeStore: envelopeStore
            ) else {
                state = .notCreated
                return
            }
            let masterKey = try VaultMasterKeyStore.load(ownerUID: ownerUID, version: summary.keyVersion)
            if masterKey == nil {
                state = .missingLocalMasterKey(summary)
            } else if summary.recoveryConfirmed {
                state = .ready(summary)
            } else {
                state = .recoveryConfirmationRequired(summary)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func summary(for document: LocalVaultEnvelopeDocument) -> LocalVaultSummary {
        LocalVaultSummary(
            createdAt: document.createdAt,
            keyVersion: document.passphraseEnvelope.masterKeyVersion,
            recoveryConfirmed: document.recoveryConfirmedAt != nil
        )
    }

    private enum RestoreCredential: Sendable {
        case passphrase(String)
        case recoveryKey(String)
    }

    private func restore(using credential: RestoreCredential) {
        guard operationTask == nil, let ownerUID = currentOwnerUID else { return }
        let envelopeStore = envelopeStore
        let document: LocalVaultEnvelopeDocument
        do {
            guard let loaded = try envelopeStore.load(ownerUID: ownerUID) else {
                throw VaultSetupError.notFound
            }
            document = loaded
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        state = .working("正在本機驗證並還原保管庫主金鑰…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    switch credential {
                    case .passphrase(let passphrase):
                        try VaultSetupService.restoreWithPassphrase(
                            ownerUID: ownerUID,
                            document: document,
                            passphrase: passphrase,
                            envelopeStore: envelopeStore
                        )
                    case .recoveryKey(let recoveryKey):
                        try VaultSetupService.restoreWithRecoveryKey(
                            ownerUID: ownerUID,
                            document: document,
                            recoveryKeyString: recoveryKey,
                            envelopeStore: envelopeStore
                        )
                    }
                }.value
                guard self.currentOwnerUID == ownerUID else { return }
                self.state = .ready(Self.summary(for: document))
            } catch {
                self.state = .failed("無法還原加密保管庫：\(error.localizedDescription)")
            }
            self.operationTask = nil
        }
    }
}
