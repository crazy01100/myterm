import Foundation

@MainActor
enum AutomaticSnippetSync {
    static func synchronize(store: CommandSnippetStore, settings: SyncSettingsStore,
                            accountStore: CloudAccountStore, vault: VaultSetupStore) async -> SyncAttemptOutcome {
        guard settings.metadataSyncEnabled else { store.setSyncMessage("離線保存於這台 Mac"); return .disabled }
        guard let account = accountStore.state.signedInAccount, let project = accountStore.firebaseProjectID else {
            store.setSyncMessage("等待 Google 登入恢復"); return .waiting("等待 Google 登入恢復")
        }
        let scope = SnippetSyncPolicy.scope(project: project, uid: account.uid)
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
        store.setSyncMessage("正在同步指令…")
        SyncDiagnosticsJournal.shared.record(.snippets, .started)
        do {
            guard case .ready = vault.state,
                  let key = try VaultMasterKeyStore.load(ownerUID: account.uid, version: VaultCryptoFormat.masterKeyVersion) else {
                throw MetadataSyncPreviewError.missingMasterKey
            }
            let token = try await accountStore.validIDToken()
            try validate()
            let result = try await SnippetSyncEngine.perform(store: store, project: project, uid: account.uid, token: token,
                key: key, deviceID: SyncDeviceIdentityStore().loadOrCreate(), backend: FirestoreSnippetBackend(projectID: project), validate: validate)
            try validate()
            let outcome: SyncAttemptOutcome
            switch result {
            case .completed: outcome = .completed
            case .conflicts: outcome = .waiting(SnippetSyncError.conflict.localizedDescription)
            case .pending: outcome = .waiting("尚有指令變更等待下一次同步。")
            }
            store.setSyncMessage(outcome.message)
            SyncDiagnosticsJournal.shared.record(.snippets, outcome == .completed ? .completed : .incomplete)
            return outcome
        } catch {
            // Never publish the old account's result after a context switch.
            guard store.generation == generation else { return .cancelled }
            let outcome: SyncAttemptOutcome
            switch error {
            case is CancellationError: outcome = .cancelled
            case FirestoreSnippetBackendError.permissionDenied: outcome = .failed("指令同步未獲允許；請確認服務的同步規則已更新。本機內容已保留。")
            case FirestoreSnippetBackendError.documentAlreadyExists: outcome = .retryable("其他裝置剛更新指令，將於下次同步重新合併。")
            case MetadataSyncPreviewError.missingMasterKey: outcome = .waiting("同步保管庫尚未就緒。")
            case let value as SnippetSyncError: outcome = .failed(value.localizedDescription)
            default: outcome = .failure(error)
            }
            store.setSyncMessage(outcome.message)
            SyncDiagnosticsJournal.shared.record(.snippets, .failed, error: error)
            return outcome
        }
    }

}
