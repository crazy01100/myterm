import Foundation

@MainActor
enum AutomaticBookmarkSync {
    static func synchronize(store: SFTPBookmarkStore, settings: SyncSettingsStore,
                            accountStore: CloudAccountStore, vault: VaultSetupStore) async -> SyncAttemptOutcome {
        guard settings.metadataSyncEnabled else { store.setSyncMessage("離線保存於這台 Mac"); return .disabled }
        guard let account = accountStore.state.signedInAccount, let project = accountStore.firebaseProjectID else {
            store.setSyncMessage("等待 Google 登入恢復"); return .waiting("等待 Google 登入恢復")
        }
        let scope = BookmarkSyncPolicy.scope(project: project, uid: account.uid)
        store.bindScope(scope)
        do {
            try store.prepareUnifiedSync(scope: scope, enabled: settings.metadataSyncEnabled)
        } catch {
            let outcome = SyncAttemptOutcome.failure(error)
            store.setSyncMessage(outcome.message)
            return outcome
        }
        let generation = store.generation
        func validate() throws {
            try Task.checkCancellation()
            guard settings.metadataSyncEnabled, accountStore.state.signedInAccount?.uid == account.uid,
                  accountStore.firebaseProjectID == project else { throw CancellationError() }
            try store.validateScope(scope, generation: generation)
        }
        store.setSyncMessage("正在同步遠端書籤…")
        SyncDiagnosticsJournal.shared.record(.bookmarks, .started)
        do {
            guard case .ready = vault.state,
                  let key = try VaultMasterKeyStore.load(ownerUID: account.uid, version: VaultCryptoFormat.masterKeyVersion) else {
                throw MetadataSyncPreviewError.missingMasterKey
            }
            let token = try await accountStore.validIDToken()
            try validate()
            let result = try await SFTPBookmarkSyncEngine.perform(store: store, project: project, uid: account.uid, token: token,
                key: key, deviceID: SyncDeviceIdentityStore().loadOrCreate(), backend: FirestoreBookmarkBackend(projectID: project), validate: validate)
            try validate()
            let outcome: SyncAttemptOutcome
            switch result {
            case .completed: outcome = .completed
            case .conflicts: outcome = .waiting(BookmarkSyncError.conflict.localizedDescription)
            case .pending: outcome = .waiting("尚有遠端書籤變更等待下一次同步。")
            }
            store.setSyncMessage(outcome.message)
            SyncDiagnosticsJournal.shared.record(.bookmarks, outcome == .completed ? .completed : .incomplete)
            return outcome
        } catch {
            // Never publish the old account's result after a context switch.
            guard store.generation == generation else { return .cancelled }
            let outcome: SyncAttemptOutcome
            switch error {
            case is CancellationError: outcome = .cancelled
            case FirestoreBookmarkBackendError.permissionDenied: outcome = .failed("遠端書籤同步未獲允許；請確認服務的同步規則已更新。本機內容已保留。")
            case FirestoreBookmarkBackendError.documentAlreadyExists: outcome = .retryable("其他裝置剛更新遠端書籤，將於下次同步重新合併。")
            case MetadataSyncPreviewError.missingMasterKey: outcome = .waiting("同步保管庫尚未就緒。")
            case let value as BookmarkSyncError: outcome = .failed(value.localizedDescription)
            default: outcome = .failure(error)
            }
            store.setSyncMessage(outcome.message)
            SyncDiagnosticsJournal.shared.record(.bookmarks, .failed, error: error)
            return outcome
        }
    }

}
