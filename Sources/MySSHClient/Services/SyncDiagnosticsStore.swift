import Combine
import Foundation

enum SyncDiagnosticLevel: Equatable {
    case passed
    case warning
    case failed
}

struct SyncDiagnosticResult: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let level: SyncDiagnosticLevel
}

@MainActor
final class SyncDiagnosticsStore: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var currentStage = ""
    @Published private(set) var results: [SyncDiagnosticResult] = []
    @Published private(set) var didFinish = false

    private var task: Task<Void, Never>?

    var hasFailure: Bool { results.contains { $0.level == .failed } }
    var hasWarning: Bool { results.contains { $0.level == .warning } }

    func run(
        hostStore: HostStore,
        settings: SyncSettingsStore,
        accountStore: CloudAccountStore,
        automaticSyncStore: AutomaticMetadataSyncStore
    ) {
        task?.cancel()
        results = []
        didFinish = false
        isRunning = true
        currentStage = "正在檢查 Google 登入狀態…"

        task = Task { [weak self, weak hostStore, weak settings, weak accountStore, weak automaticSyncStore] in
            guard let self, let hostStore, let settings, let accountStore, let automaticSyncStore else { return }
            await self.perform(
                hostStore: hostStore,
                settings: settings,
                accountStore: accountStore,
                automaticSyncStore: automaticSyncStore
            )
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func perform(
        hostStore: HostStore,
        settings: SyncSettingsStore,
        accountStore: CloudAccountStore,
        automaticSyncStore: AutomaticMetadataSyncStore
    ) async {
        defer {
            task = nil
            isRunning = false
            didFinish = true
            currentStage = ""
        }

        guard case .signedIn(let account) = accountStore.state else {
            fail("google-account", "Google 帳號", "尚未登入 Google；請先完成登入後再執行檢測。")
            return
        }
        pass("google-account", "Google 帳號", "已登入目前用於跨裝置同步的 Google 帳號。")

        guard let projectID = accountStore.firebaseProjectID else {
            fail("cloud-config", "同步服務設定", "這個版本缺少雲端同步設定，請重新安裝完整版本。")
            return
        }

        currentStage = "正在驗證登入憑證…"
        let idToken: String
        do {
            idToken = try await accountStore.validIDToken()
            try Task.checkCancellation()
            pass("login-token", "登入憑證", "Google 登入憑證有效，可以安全存取這個帳號的同步資料。")
        } catch is CancellationError {
            return
        } catch {
            fail("login-token", "登入憑證", publicError(error))
            return
        }

        currentStage = "正在檢查本機加密保管庫…"
        let localEnvelope: LocalVaultEnvelopeDocument
        let masterKey: VaultMasterKey
        do {
            guard let envelope = try VaultEnvelopeStore().load(ownerUID: account.uid) else {
                fail("local-vault", "本機加密保管庫", "找不到這台 Mac 的加密保管庫；請關閉同步後重新啟用。")
                return
            }
            guard envelope.recoveryConfirmedAt != nil else {
                fail("local-vault", "本機加密保管庫", "復原金鑰尚未確認保存，保管庫設定並未完整完成。")
                return
            }
            guard let key = try VaultMasterKeyStore.load(
                ownerUID: account.uid,
                version: envelope.passphraseEnvelope.masterKeyVersion
            ) else {
                fail("local-vault", "本機加密保管庫", "Keychain 中找不到這個帳號的加密主金鑰。")
                return
            }
            localEnvelope = envelope
            masterKey = key
            pass("local-vault", "本機加密保管庫", "加密封套、復原狀態與 Keychain 主金鑰均可正常讀取。")
        } catch {
            fail("local-vault", "本機加密保管庫", publicError(error))
            return
        }

        currentStage = "正在檢查雲端加密封套…"
        do {
            guard let cloudEnvelope = try await FirestoreVaultBackend(projectID: projectID).fetchEnvelope(
                ownerUID: account.uid,
                idToken: idToken
            ) else {
                fail("cloud-envelope", "雲端加密封套", "雲端找不到這個帳號的加密封套。")
                return
            }
            try Task.checkCancellation()
            guard cloudEnvelope == localEnvelope else {
                fail("cloud-envelope", "雲端加密封套", "本機與雲端的加密封套不一致，為避免使用錯誤金鑰已停止檢測。")
                return
            }
            pass("cloud-envelope", "雲端加密封套", "本機與雲端封套一致。")
        } catch is CancellationError {
            return
        } catch {
            fail("cloud-envelope", "雲端加密封套", publicError(error))
            return
        }

        currentStage = "正在驗證端對端加密資料…"
        let snapshot: FirestoreMetadataSnapshot
        do {
            snapshot = try await FirestoreMetadataBackend(projectID: projectID).fetchSnapshot(
                ownerUID: account.uid,
                idToken: idToken
            )
            try Task.checkCancellation()
            let metadataRecords = snapshot.records.filter { $0.recordType == .group || $0.recordType == .host }
            let passwordRecords = snapshot.records.filter { $0.recordType == .password }
            for record in metadataRecords {
                _ = try MetadataSyncCodec.decrypt(record, ownerUID: account.uid, masterKey: masterKey)
            }
            for record in passwordRecords {
                if record.deleted {
                    try PasswordSyncCodec.validateTombstone(record, ownerUID: account.uid, masterKey: masterKey)
                } else {
                    var decrypted = try PasswordSyncCodec.decrypt(
                        record,
                        ownerUID: account.uid,
                        masterKey: masterKey
                    ).passwordData
                    decrypted.resetBytes(in: decrypted.startIndex..<decrypted.endIndex)
                }
            }
            pass(
                "encrypted-records",
                "端對端加密資料",
                "已驗證 \(metadataRecords.count) 筆主機／群組與 \(passwordRecords.count) 筆密碼紀錄，全部可由這台 Mac 正確解密。"
            )
        } catch is CancellationError {
            return
        } catch {
            fail("encrypted-records", "端對端加密資料", publicError(error))
            return
        }

        currentStage = "正在檢查同步基線…"
        do {
            let metadataRecords = snapshot.records.filter { $0.recordType == .group || $0.recordType == .host }
            guard let baseline = try MetadataSyncBaselineStore().load(ownerUID: account.uid) else {
                fail("metadata-baseline", "主機與群組同步基線", "找不到這台 Mac 的同步基線；自動同步無法安全判斷變更方向。")
                return
            }
            let plan = try MetadataManualSyncPlanner.makePlan(
                localGroups: hostStore.groups,
                localHosts: hostStore.hosts,
                remoteRecords: metadataRecords,
                baseline: baseline,
                ownerUID: account.uid,
                masterKey: masterKey
            )
            if plan.conflictCount > 0 {
                fail("metadata-baseline", "主機與群組同步基線", "偵測到 \(plan.conflictCount) 筆同時變更，請回到帳號與同步頁確認處理。")
            } else if plan.uploadCount + plan.downloadCount + plan.repairCount + plan.deletionCount > 0 {
                let pendingCount = plan.uploadCount + plan.downloadCount + plan.repairCount + plan.deletionCount
                warn(
                    "metadata-baseline",
                    "主機與群組同步基線",
                    "基線有效，但目前有 \(pendingCount) 筆變更或刪除尚待同步。"
                )
            } else {
                pass("metadata-baseline", "主機與群組同步基線", "本機、雲端與同步基線一致。")
            }
        } catch {
            fail("metadata-baseline", "主機與群組同步基線", publicError(error))
        }

        currentStage = "正在檢查密碼同步狀態…"
        do {
            let cloudPasswordRecords = snapshot.records.filter { $0.recordType == .password && !$0.deleted }
            let localPasswordHostIDs = Set(hostStore.hosts.filter {
                $0.authenticationMethod == .password && KeychainStore.containsPassword(for: $0.id)
            }.map(\.id))
            var cloudPasswordHostIDs: Set<UUID> = []
            var mismatchedCount = 0
            for record in cloudPasswordRecords {
                var decrypted = try PasswordSyncCodec.decrypt(record, ownerUID: account.uid, masterKey: masterKey)
                defer { decrypted.passwordData.resetBytes(in: decrypted.passwordData.startIndex..<decrypted.passwordData.endIndex) }
                cloudPasswordHostIDs.insert(decrypted.hostID)
                guard var localData = try KeychainStore.passwordData(for: decrypted.hostID) else {
                    mismatchedCount += 1
                    continue
                }
                defer { localData.resetBytes(in: localData.startIndex..<localData.endIndex) }
                if localData != decrypted.passwordData { mismatchedCount += 1 }
            }
            let baseline = try PasswordSyncBaselineStore().load(ownerUID: account.uid)
            let identityMismatch = localPasswordHostIDs != cloudPasswordHostIDs
            if baseline == nil && (!localPasswordHostIDs.isEmpty || !cloudPasswordHostIDs.isEmpty) {
                fail("password-sync", "密碼同步", "找不到這台 Mac 的密碼同步基線。")
            } else if identityMismatch || mismatchedCount > 0 {
                warn("password-sync", "密碼同步", "Keychain 與雲端密碼尚未完全一致，下一次同步會重新整理。")
            } else {
                pass("password-sync", "密碼同步", "已驗證 \(localPasswordHostIDs.count) 組 Keychain 密碼與雲端加密紀錄一致。")
            }
        } catch {
            fail("password-sync", "密碼同步", publicError(error))
        }

        currentStage = "正在檢查自動同步狀態…"
        if !settings.metadataSyncEnabled {
            warn("automatic-sync", "自動同步", "同步開關目前是關閉狀態。")
        } else {
            switch automaticSyncStore.status {
            case .failed(let message):
                fail("automatic-sync", "自動同步", message)
            case .paused(let message):
                warn("automatic-sync", "自動同步", message)
            case .waitingForConfirmation(let count):
                warn("automatic-sync", "自動同步", "有 \(count) 筆近期變更正在等待你的確認。")
            case .disabled:
                warn("automatic-sync", "自動同步", "同步開關已開啟，但自動同步程序尚未啟動。")
            case .scheduled, .syncing:
                pass("automatic-sync", "自動同步", "自動同步程序目前正在正常運作。")
            case .idle:
                if let date = automaticSyncStore.lastSuccessfulSyncAt {
                    pass(
                        "automatic-sync",
                        "自動同步",
                        "同步程序就緒；上次成功時間：\(date.formatted(date: .abbreviated, time: .standard))。"
                    )
                } else {
                    warn("automatic-sync", "自動同步", "同步程序就緒，但這台 Mac 尚無成功同步紀錄。")
                }
            }
        }
    }

    private func pass(_ id: String, _ title: String, _ detail: String) {
        results.append(.init(id: id, title: title, detail: detail, level: .passed))
    }

    private func warn(_ id: String, _ title: String, _ detail: String) {
        results.append(.init(id: id, title: title, detail: detail, level: .warning))
    }

    private func fail(_ id: String, _ title: String, _ detail: String) {
        results.append(.init(id: id, title: title, detail: detail, level: .failed))
    }

    private func publicError(_ error: Error) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: "Firebase", with: "雲端同步服務")
            .replacingOccurrences(of: "Firestore Security Rules", with: "雲端存取規則")
            .replacingOccurrences(of: "Firestore", with: "雲端同步服務")
        return message.isEmpty ? "檢測時發生未知錯誤。" : message
    }
}
