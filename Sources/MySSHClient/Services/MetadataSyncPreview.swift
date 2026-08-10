import Combine
import Foundation

enum MetadataSyncPreviewDisposition: String, Equatable, Sendable {
    case upload
    case download
    case conflict
    case unchanged
    case remoteTombstone

    var title: String {
        switch self {
        case .upload: "將上傳"
        case .download: "將下載"
        case .conflict: "需要處理衝突"
        case .unchanged: "內容相同"
        case .remoteTombstone: "雲端刪除紀錄"
        }
    }
}

struct MetadataSyncPreviewItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let recordType: SyncRecordType
    let displayName: String
    let disposition: MetadataSyncPreviewDisposition
    let detail: String
    let remoteRevision: UInt64?
}

struct MetadataSyncPreview: Equatable, Sendable {
    let generatedAt: Date
    let localGroupCount: Int
    let localHostCount: Int
    let remoteGroupCount: Int
    let remoteHostCount: Int
    let items: [MetadataSyncPreviewItem]

    var uploadCount: Int { count(.upload) }
    var downloadCount: Int { count(.download) }
    var conflictCount: Int { count(.conflict) }
    var unchangedCount: Int { count(.unchanged) }
    var remoteTombstoneCount: Int { count(.remoteTombstone) }

    private func count(_ disposition: MetadataSyncPreviewDisposition) -> Int {
        items.count { $0.disposition == disposition }
    }
}

enum MetadataSyncPreviewError: LocalizedError, Equatable {
    case tooManyRecords
    case duplicateLocalIdentity
    case duplicateRemoteIdentity
    case invalidRemoteHierarchy
    case missingRemoteGroup
    case missingMasterKey

    var errorDescription: String? {
        switch self {
        case .tooManyRecords: "同步預覽的紀錄數超過安全上限。"
        case .duplicateLocalIdentity: "本機主機或群組包含重複的識別碼，已停止預覽。"
        case .duplicateRemoteIdentity: "雲端同步資料包含重複或類型衝突的識別碼，已停止預覽。"
        case .invalidRemoteHierarchy: "雲端群組階層含有循環或無效關係，已停止預覽。"
        case .missingRemoteGroup: "雲端主機指向不存在的群組，已停止預覽。"
        case .missingMasterKey: "這台 Mac 缺少端對端加密主金鑰。"
        }
    }
}

enum MetadataSyncPreviewPlanner {
    static let maximumRecordCount = 10_000

    static func makePreview(
        localGroups: [HostGroup],
        localHosts: [HostProfile],
        remoteRecords: [EncryptedSyncRecord],
        ownerUID: String,
        masterKey: VaultMasterKey,
        generatedAt: Date = .now
    ) throws -> MetadataSyncPreview {
        guard localGroups.count + localHosts.count <= maximumRecordCount,
              remoteRecords.count <= maximumRecordCount else {
            throw MetadataSyncPreviewError.tooManyRecords
        }

        var local: [UUID: LocalMetadataValue] = [:]
        for group in localGroups {
            guard local[group.id] == nil else { throw MetadataSyncPreviewError.duplicateLocalIdentity }
            local[group.id] = .group(group)
        }
        for host in localHosts {
            guard local[host.id] == nil else { throw MetadataSyncPreviewError.duplicateLocalIdentity }
            local[host.id] = .host(normalized(host))
        }

        var remote: [UUID: RemoteMetadataValue] = [:]
        for record in remoteRecords {
            guard remote[record.id] == nil else { throw MetadataSyncPreviewError.duplicateRemoteIdentity }
            let decrypted = try MetadataSyncCodec.decrypt(record, ownerUID: ownerUID, masterKey: masterKey)
            let value: RemoteMetadataValue
            switch decrypted {
            case .group(let group): value = .group(group, record)
            case .host(let host): value = .host(normalized(host), record)
            case .tombstone(let id, let type):
                guard id == record.id, type == record.recordType else {
                    throw MetadataSyncPreviewError.duplicateRemoteIdentity
                }
                value = .tombstone(type, record)
            }
            remote[record.id] = value
        }

        try validateRemoteRelationships(local: local, remote: remote)

        let allIDs = Set(local.keys).union(remote.keys)
        let items = try allIDs.map { id in
            try previewItem(id: id, local: local[id], remote: remote[id])
        }.sorted {
            if $0.disposition != $1.disposition {
                return dispositionOrder($0.disposition) < dispositionOrder($1.disposition)
            }
            let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
            return nameOrder == .orderedSame ? $0.id.uuidString < $1.id.uuidString : nameOrder == .orderedAscending
        }

        let remoteGroups = remote.values.count {
            if case .group = $0 { return true }
            return false
        }
        let remoteHosts = remote.values.count {
            if case .host = $0 { return true }
            return false
        }
        return MetadataSyncPreview(
            generatedAt: generatedAt,
            localGroupCount: localGroups.count,
            localHostCount: localHosts.count,
            remoteGroupCount: remoteGroups,
            remoteHostCount: remoteHosts,
            items: items
        )
    }

    private static func previewItem(
        id: UUID,
        local: LocalMetadataValue?,
        remote: RemoteMetadataValue?
    ) throws -> MetadataSyncPreviewItem {
        switch (local, remote) {
        case (.group(let group), nil):
            return item(id, .group, group.name, .upload, "只存在這台 Mac。", nil)
        case (.host(let host), nil):
            return item(id, .host, host.displayName, .upload, "只存在這台 Mac。", nil)
        case (nil, .group(let group, let record)):
            return item(id, .group, group.name, .download, "只存在雲端密文。", record.revision)
        case (nil, .host(let host, let record)):
            return item(id, .host, host.displayName, .download, "只存在雲端密文。", record.revision)
        case (nil, .tombstone(let type, let record)):
            return item(id, type, "已刪除的紀錄", .remoteTombstone, "本機沒有對應資料，不需要動作。", record.revision)
        case (.group(let localGroup), .group(let remoteGroup, let record)):
            let same = localGroup == remoteGroup
            return item(
                id, .group, localGroup.name,
                same ? .unchanged : .conflict,
                same ? "本機與雲端解密內容相同。" : "同一群組在兩端的內容不同，不會自動覆蓋。",
                record.revision
            )
        case (.host(let localHost), .host(let remoteHost, let record)):
            let same = localHost == remoteHost
            return item(
                id, .host, localHost.displayName,
                same ? .unchanged : .conflict,
                same ? "本機與雲端解密內容相同。" : "同一主機在兩端的內容不同，不會自動覆蓋。",
                record.revision
            )
        case (.group(let group), .tombstone(_, let record)):
            return item(id, .group, group.name, .conflict, "雲端已有刪除標記，但本機仍保留此群組。", record.revision)
        case (.host(let host), .tombstone(_, let record)):
            return item(id, .host, host.displayName, .conflict, "雲端已有刪除標記，但本機仍保留此主機。", record.revision)
        case (.some(let localValue), .some(let remoteValue)):
            let type = localValue.recordType
            return item(
                id,
                type,
                localValue.displayName,
                .conflict,
                "相同識別碼在兩端代表不同資料類型，不會自動處理。",
                remoteValue.record.revision
            )
        case (nil, nil):
            throw MetadataSyncPreviewError.duplicateRemoteIdentity
        }
    }

    private static func validateRemoteRelationships(
        local: [UUID: LocalMetadataValue],
        remote: [UUID: RemoteMetadataValue]
    ) throws {
        var effectiveGroups: [UUID: HostGroup] = [:]
        for (id, value) in local {
            if case .group(let group) = value { effectiveGroups[id] = group }
        }
        for (id, value) in remote {
            switch value {
            case .group(let group, _): effectiveGroups[id] = group
            case .tombstone(let type, _) where type == .group: effectiveGroups[id] = nil
            default: break
            }
        }

        for group in effectiveGroups.values {
            if let parentID = group.parentID, effectiveGroups[parentID] == nil {
                throw MetadataSyncPreviewError.invalidRemoteHierarchy
            }
            var visited: Set<UUID> = [group.id]
            var current = group.parentID
            while let id = current {
                guard visited.insert(id).inserted else {
                    throw MetadataSyncPreviewError.invalidRemoteHierarchy
                }
                current = effectiveGroups[id]?.parentID
            }
        }

        for value in remote.values {
            guard case .host(let host, _) = value, let groupID = host.groupID else { continue }
            guard effectiveGroups[groupID] != nil else {
                throw MetadataSyncPreviewError.missingRemoteGroup
            }
        }
    }

    private static func normalized(_ host: HostProfile) -> HostProfile {
        var result = host
        result.privateKeyPath = ""
        result.legacyGroupName = nil
        return result
    }

    private static func item(
        _ id: UUID,
        _ type: SyncRecordType,
        _ name: String,
        _ disposition: MetadataSyncPreviewDisposition,
        _ detail: String,
        _ revision: UInt64?
    ) -> MetadataSyncPreviewItem {
        MetadataSyncPreviewItem(
            id: id,
            recordType: type,
            displayName: name.isEmpty ? id.uuidString : name,
            disposition: disposition,
            detail: detail,
            remoteRevision: revision
        )
    }

    private static func dispositionOrder(_ value: MetadataSyncPreviewDisposition) -> Int {
        switch value {
        case .conflict: 0
        case .upload: 1
        case .download: 2
        case .unchanged: 3
        case .remoteTombstone: 4
        }
    }
}

enum MetadataSyncInitializationError: LocalizedError, Equatable {
    case previewOutdated
    case cloudNoLongerEmpty
    case previewNotEligible
    case nothingToUpload
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .previewOutdated: "本機資料已在預覽後改變，請重新建立同步預覽。"
        case .cloudNoLongerEmpty: "雲端已在預覽後出現主機資料，已停止上傳；請重新建立預覽。"
        case .previewNotEligible: "這份預覽包含雲端資料或衝突，不能用來初始化空的雲端保管庫。"
        case .nothingToUpload: "目前沒有本機主機或群組需要上傳。"
        case .verificationFailed: "上傳後的加密資料驗證未通過；同步仍保持關閉。"
        }
    }
}

enum MetadataSyncRestoreError: LocalizedError, Equatable {
    case previewOutdated
    case localInventoryNotEmpty
    case previewNotEligible
    case nothingToDownload

    var errorDescription: String? {
        switch self {
        case .previewOutdated: "雲端資料已在預覽後改變，請重新建立同步預覽。"
        case .localInventoryNotEmpty: "這台 Mac 已有主機或群組，空白裝置還原已停止。"
        case .previewNotEligible: "這份預覽不符合空白裝置安全還原條件。"
        case .nothingToDownload: "雲端沒有可還原的主機或群組。"
        }
    }
}

enum CloudInventoryRestoreError: LocalizedError, Equatable {
    case localInventoryNotEmpty
    case invalidInventory

    var errorDescription: String? {
        switch self {
        case .localInventoryNotEmpty: "這台 Mac 已有主機或群組，無法套用空白裝置還原。"
        case .invalidInventory: "雲端解密後的主機或群組結構不正確，已停止還原。"
        }
    }
}

enum CloudInventoryRestoreValidator {
    static func validate(_ document: InventoryDocument) throws {
        var allIDs: Set<UUID> = []
        guard document.groups.allSatisfy({ allIDs.insert($0.id).inserted }),
              document.hosts.allSatisfy({ allIDs.insert($0.id).inserted }) else {
            throw CloudInventoryRestoreError.invalidInventory
        }
        let groupsByID = Dictionary(uniqueKeysWithValues: document.groups.map { ($0.id, $0) })
        for group in document.groups {
            guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CloudInventoryRestoreError.invalidInventory
            }
            if let parentID = group.parentID, groupsByID[parentID] == nil {
                throw CloudInventoryRestoreError.invalidInventory
            }
            var visited: Set<UUID> = [group.id]
            var current = group.parentID
            while let id = current {
                guard visited.insert(id).inserted else {
                    throw CloudInventoryRestoreError.invalidInventory
                }
                current = groupsByID[id]?.parentID
            }
        }
        for (index, group) in document.groups.enumerated() {
            let duplicate = document.groups.dropFirst(index + 1).contains {
                $0.parentID == group.parentID
                    && $0.name.localizedCaseInsensitiveCompare(group.name) == .orderedSame
            }
            guard !duplicate else { throw CloudInventoryRestoreError.invalidInventory }
        }
        for host in document.hosts {
            guard host.privateKeyPath.isEmpty,
                  host.groupID.map({ groupsByID[$0] != nil }) ?? true else {
                throw CloudInventoryRestoreError.invalidInventory
            }
        }
    }
}

enum MetadataSyncInitialUploadPlanner {
    static func makeRecords(
        groups: [HostGroup],
        hosts: [HostProfile],
        ownerUID: String,
        masterKey: VaultMasterKey,
        deviceID: UUID
    ) throws -> [EncryptedSyncRecord] {
        guard groups.count + hosts.count <= MetadataSyncPreviewPlanner.maximumRecordCount else {
            throw MetadataSyncPreviewError.tooManyRecords
        }
        var seen: Set<UUID> = []
        guard groups.allSatisfy({ seen.insert($0.id).inserted }),
              hosts.allSatisfy({ seen.insert($0.id).inserted }) else {
            throw MetadataSyncPreviewError.duplicateLocalIdentity
        }

        let groupRecords = try groups.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            try MetadataSyncCodec.encrypt(
                group: $0,
                ownerUID: ownerUID,
                masterKey: masterKey,
                revision: 1,
                modifiedByDeviceID: deviceID
            )
        }
        let hostRecords = try hosts.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            try MetadataSyncCodec.encrypt(
                host: $0,
                ownerUID: ownerUID,
                masterKey: masterKey,
                revision: 1,
                modifiedByDeviceID: deviceID
            )
        }
        return groupRecords + hostRecords
    }
}

enum MetadataSyncCloudRestorePlanner {
    static func makeInventory(
        remoteRecords: [EncryptedSyncRecord],
        ownerUID: String,
        masterKey: VaultMasterKey
    ) throws -> InventoryDocument {
        let preview = try MetadataSyncPreviewPlanner.makePreview(
            localGroups: [],
            localHosts: [],
            remoteRecords: remoteRecords,
            ownerUID: ownerUID,
            masterKey: masterKey
        )
        guard preview.uploadCount == 0,
              preview.conflictCount == 0,
              preview.unchangedCount == 0 else {
            throw MetadataSyncRestoreError.previewNotEligible
        }
        guard preview.downloadCount > 0 else {
            throw MetadataSyncRestoreError.nothingToDownload
        }

        var groups: [HostGroup] = []
        var hosts: [HostProfile] = []
        for record in remoteRecords {
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
}

enum MetadataSyncPreviewState: Equatable {
    case idle
    case loading
    case ready(MetadataSyncPreview)
    case failed(String)
}

enum MetadataSyncInitializationState: Equatable {
    case idle
    case uploading(completed: Int, total: Int)
    case completed(uploaded: Int)
    case failed(String)
}

enum MetadataSyncBaselineState: Equatable {
    case idle
    case ready(MetadataSyncBaselineSummary)
    case failed(String)
}

enum MetadataManualSyncExecutionState: Equatable {
    case idle
    case syncing(completed: Int, total: Int)
    case completed(uploaded: Int, repaired: Int)
    case failed(String)
}

enum MetadataManualDownloadState: Equatable {
    case idle
    case downloading
    case completed(downloaded: Int)
    case failed(String)
}

@MainActor
final class MetadataSyncPreviewStore: ObservableObject {
    @Published private(set) var state: MetadataSyncPreviewState = .idle
    @Published private(set) var initializationState: MetadataSyncInitializationState = .idle
    @Published private(set) var baselineState: MetadataSyncBaselineState = .idle
    @Published private(set) var manualPlan: MetadataManualSyncPlan?
    @Published private(set) var manualSyncState: MetadataManualSyncExecutionState = .idle
    @Published private(set) var manualDownloadState: MetadataManualDownloadState = .idle
    private var previewTask: Task<Void, Never>?
    private var initializationTask: Task<Void, Never>?
    private var manualSyncTask: Task<Void, Never>?
    private var previewContext: PreviewContext?

    var canEstablishRemoteAnchorBaseline: Bool {
        guard case .ready(let preview) = state,
              previewContext?.baseline == nil else { return false }
        let localCount = preview.localGroupCount + preview.localHostCount
        let remoteCount = preview.remoteGroupCount + preview.remoteHostCount
        return localCount > 0
            && localCount == remoteCount
            && preview.uploadCount == 0
            && preview.downloadCount == 0
            && preview.remoteTombstoneCount == 0
            && preview.conflictCount + preview.unchangedCount == localCount
    }

    func prepare(
        projectID: String,
        ownerUID: String,
        idToken: String,
        localGroups: [HostGroup],
        localHosts: [HostProfile]
    ) {
        guard previewTask == nil else { return }
        initializationState = .idle
        previewContext = nil
        state = .loading
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let existingBaseline = try MetadataSyncBaselineStore().load(ownerUID: ownerUID)
                if let existing = existingBaseline {
                    self.baselineState = .ready(MetadataSyncBaselinePlanner.summary(existing))
                } else {
                    self.baselineState = .idle
                }
                guard let masterKey = try VaultMasterKeyStore.load(
                    ownerUID: ownerUID,
                    version: VaultCryptoFormat.masterKeyVersion
                ) else {
                    throw MetadataSyncPreviewError.missingMasterKey
                }
                let backend = FirestoreMetadataBackend(projectID: projectID)
                let remoteRecords = try await backend.fetchAll(ownerUID: ownerUID, idToken: idToken)
                guard !Task.isCancelled else { return }
                let preview: MetadataSyncPreview
                let manualPlan: MetadataManualSyncPlan?
                if let existingBaseline {
                    let plan = try MetadataManualSyncPlanner.makePlan(
                        localGroups: localGroups,
                        localHosts: localHosts,
                        remoteRecords: remoteRecords,
                        baseline: existingBaseline,
                        ownerUID: ownerUID,
                        masterKey: masterKey
                    )
                    preview = plan.preview
                    manualPlan = plan
                } else {
                    preview = try MetadataSyncPreviewPlanner.makePreview(
                        localGroups: localGroups,
                        localHosts: localHosts,
                        remoteRecords: remoteRecords,
                        ownerUID: ownerUID,
                        masterKey: masterKey
                    )
                    manualPlan = nil
                }
                self.state = .ready(preview)
                self.manualPlan = manualPlan
                self.previewContext = PreviewContext(
                    ownerUID: ownerUID,
                    groups: localGroups,
                    hosts: localHosts,
                    remoteRecords: Self.sorted(remoteRecords),
                    baseline: existingBaseline
                )
            } catch is CancellationError {
                self.state = .idle
            } catch {
                self.state = .failed(error.localizedDescription)
            }
            self.previewTask = nil
        }
    }

    func initializeEmptyCloud(
        projectID: String,
        ownerUID: String,
        idToken: String,
        currentGroups: [HostGroup],
        currentHosts: [HostProfile]
    ) {
        guard initializationTask == nil,
              case .ready(let preview) = state,
              let context = previewContext,
              context.ownerUID == ownerUID else { return }

        let total = currentGroups.count + currentHosts.count
        guard total > 0 else {
            initializationState = .failed(MetadataSyncInitializationError.nothingToUpload.localizedDescription)
            return
        }
        guard preview.remoteGroupCount == 0,
              preview.remoteHostCount == 0,
              preview.remoteTombstoneCount == 0,
              preview.downloadCount == 0,
              preview.conflictCount == 0,
              preview.unchangedCount == 0,
              preview.uploadCount == total else {
            initializationState = .failed(MetadataSyncInitializationError.previewNotEligible.localizedDescription)
            return
        }
        guard context.groups == currentGroups, context.hosts == currentHosts else {
            initializationState = .failed(MetadataSyncInitializationError.previewOutdated.localizedDescription)
            return
        }

        initializationState = .uploading(completed: 0, total: total)
        initializationTask = Task { [weak self] in
            guard let self else { return }
            var completed = 0
            do {
                guard let masterKey = try VaultMasterKeyStore.load(
                    ownerUID: ownerUID,
                    version: VaultCryptoFormat.masterKeyVersion
                ) else {
                    throw MetadataSyncPreviewError.missingMasterKey
                }
                let backend = FirestoreMetadataBackend(projectID: projectID)
                let latestRemote = try await backend.fetchAll(ownerUID: ownerUID, idToken: idToken)
                guard latestRemote.isEmpty else {
                    throw MetadataSyncInitializationError.cloudNoLongerEmpty
                }
                guard !Task.isCancelled else { throw CancellationError() }

                let deviceID = try SyncDeviceIdentityStore().loadOrCreate()
                let records = try MetadataSyncInitialUploadPlanner.makeRecords(
                    groups: currentGroups,
                    hosts: currentHosts,
                    ownerUID: ownerUID,
                    masterKey: masterKey,
                    deviceID: deviceID
                )
                for record in records {
                    try await backend.create(record, ownerUID: ownerUID, idToken: idToken)
                    completed += 1
                    self.initializationState = .uploading(completed: completed, total: records.count)
                    guard !Task.isCancelled else { throw CancellationError() }
                }

                let verifiedRemote = try await backend.fetchAll(ownerUID: ownerUID, idToken: idToken)
                let verifiedPreview = try MetadataSyncPreviewPlanner.makePreview(
                    localGroups: currentGroups,
                    localHosts: currentHosts,
                    remoteRecords: verifiedRemote,
                    ownerUID: ownerUID,
                    masterKey: masterKey
                )
                guard verifiedRemote.count == records.count,
                      verifiedPreview.unchangedCount == records.count,
                      verifiedPreview.uploadCount == 0,
                      verifiedPreview.downloadCount == 0,
                      verifiedPreview.conflictCount == 0 else {
                    throw MetadataSyncInitializationError.verificationFailed
                }
                self.state = .ready(verifiedPreview)
                self.previewContext = PreviewContext(
                    ownerUID: ownerUID,
                    groups: currentGroups,
                    hosts: currentHosts,
                    remoteRecords: Self.sorted(verifiedRemote),
                    baseline: nil
                )
                self.initializationState = .completed(uploaded: records.count)
            } catch is CancellationError {
                self.initializationState = .idle
            } catch {
                let prefix = completed > 0 ? "已完成 \(completed) 筆後停止。" : ""
                self.initializationState = .failed(prefix + error.localizedDescription)
            }
            self.initializationTask = nil
        }
    }

    func verifiedEmptyLocalRestore(
        projectID: String,
        ownerUID: String,
        idToken: String,
        currentGroups: [HostGroup],
        currentHosts: [HostProfile]
    ) async throws -> MetadataManualDownloadResult {
        guard case .ready(let preview) = state,
              let context = previewContext,
              context.ownerUID == ownerUID else {
            throw MetadataSyncRestoreError.previewOutdated
        }
        guard currentGroups.isEmpty, currentHosts.isEmpty,
              context.groups.isEmpty, context.hosts.isEmpty else {
            throw MetadataSyncRestoreError.localInventoryNotEmpty
        }
        guard preview.uploadCount == 0,
              preview.conflictCount == 0,
              preview.unchangedCount == 0,
              preview.downloadCount > 0,
              preview.downloadCount == preview.remoteGroupCount + preview.remoteHostCount else {
            throw MetadataSyncRestoreError.previewNotEligible
        }

        guard let masterKey = try VaultMasterKeyStore.load(
            ownerUID: ownerUID,
            version: VaultCryptoFormat.masterKeyVersion
        ) else {
            throw MetadataSyncPreviewError.missingMasterKey
        }
        let backend = FirestoreMetadataBackend(projectID: projectID)
        let latestRemote = try await backend.fetchAll(ownerUID: ownerUID, idToken: idToken)
        guard Self.sorted(latestRemote) == context.remoteRecords else {
            throw MetadataSyncRestoreError.previewOutdated
        }
        let document = try MetadataSyncCloudRestorePlanner.makeInventory(
            remoteRecords: latestRemote,
            ownerUID: ownerUID,
            masterKey: masterKey
        )
        let deviceID = try SyncDeviceIdentityStore().loadOrCreate()
        let baseline = try MetadataSyncBaselinePlanner.makeBaseline(
            localGroups: document.groups,
            localHosts: document.hosts,
            remoteRecords: latestRemote,
            ownerUID: ownerUID,
            masterKey: masterKey,
            deviceID: deviceID
        )
        return MetadataManualDownloadResult(
            document: document,
            baseline: baseline,
            remoteRecords: Self.sorted(latestRemote),
            downloadedCount: document.groups.count + document.hosts.count
        )
    }

    @discardableResult
    func establishRemoteAnchorBaseline(
        ownerUID: String,
        currentGroups: [HostGroup],
        currentHosts: [HostProfile]
    ) throws -> MetadataSyncBaselineSummary {
        guard canEstablishRemoteAnchorBaseline,
              let context = previewContext,
              context.ownerUID == ownerUID,
              context.baseline == nil,
              context.groups == currentGroups,
              context.hosts == currentHosts else {
            throw MetadataSyncBaselineError.previewOutdated
        }
        do {
            guard let masterKey = try VaultMasterKeyStore.load(
                ownerUID: ownerUID,
                version: VaultCryptoFormat.masterKeyVersion
            ) else {
                throw MetadataSyncPreviewError.missingMasterKey
            }
            let remoteInventory = try MetadataSyncCloudRestorePlanner.makeInventory(
                remoteRecords: context.remoteRecords,
                ownerUID: ownerUID,
                masterKey: masterKey
            )
            guard Set(remoteInventory.groups.map(\.id)) == Set(currentGroups.map(\.id)),
                  Set(remoteInventory.hosts.map(\.id)) == Set(currentHosts.map(\.id)) else {
                throw MetadataSyncBaselineError.previewNotEligible
            }
            let deviceID = try SyncDeviceIdentityStore().loadOrCreate()
            let baseline = try MetadataSyncBaselinePlanner.makeBaseline(
                localGroups: remoteInventory.groups,
                localHosts: remoteInventory.hosts,
                remoteRecords: context.remoteRecords,
                ownerUID: ownerUID,
                masterKey: masterKey,
                deviceID: deviceID
            )
            let plan = try MetadataManualSyncPlanner.makePlan(
                localGroups: currentGroups,
                localHosts: currentHosts,
                remoteRecords: context.remoteRecords,
                baseline: baseline,
                ownerUID: ownerUID,
                masterKey: masterKey
            )
            guard plan.downloadCount == 0,
                  plan.conflictCount == 0,
                  plan.items.count == currentGroups.count + currentHosts.count else {
                throw MetadataSyncBaselineError.previewNotEligible
            }
            try MetadataSyncBaselineStore().save(baseline, ownerUID: ownerUID)
            let summary = MetadataSyncBaselinePlanner.summary(baseline)
            baselineState = .ready(summary)
            manualPlan = plan
            state = .ready(plan.preview)
            previewContext = PreviewContext(
                ownerUID: ownerUID,
                groups: currentGroups,
                hosts: currentHosts,
                remoteRecords: context.remoteRecords,
                baseline: baseline
            )
            return summary
        } catch {
            baselineState = .failed(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func establishBaseline(
        ownerUID: String,
        currentGroups: [HostGroup],
        currentHosts: [HostProfile]
    ) throws -> MetadataSyncBaselineSummary {
        guard case .ready(let preview) = state,
              let context = previewContext,
              context.ownerUID == ownerUID,
              context.groups == currentGroups,
              context.hosts == currentHosts else {
            throw MetadataSyncBaselineError.previewOutdated
        }
        let expectedCount = currentGroups.count + currentHosts.count
        guard expectedCount > 0,
              preview.unchangedCount == expectedCount,
              preview.uploadCount == 0,
              preview.downloadCount == 0,
              preview.conflictCount == 0,
              preview.remoteTombstoneCount == 0 else {
            throw MetadataSyncBaselineError.previewNotEligible
        }
        do {
            guard let masterKey = try VaultMasterKeyStore.load(
                ownerUID: ownerUID,
                version: VaultCryptoFormat.masterKeyVersion
            ) else {
                throw MetadataSyncPreviewError.missingMasterKey
            }
            let deviceID = try SyncDeviceIdentityStore().loadOrCreate()
            let baseline = try MetadataSyncBaselinePlanner.makeBaseline(
                localGroups: currentGroups,
                localHosts: currentHosts,
                remoteRecords: context.remoteRecords,
                ownerUID: ownerUID,
                masterKey: masterKey,
                deviceID: deviceID
            )
            try MetadataSyncBaselineStore().save(baseline, ownerUID: ownerUID)
            let summary = MetadataSyncBaselinePlanner.summary(baseline)
            baselineState = .ready(summary)
            let plan = try MetadataManualSyncPlanner.makePlan(
                localGroups: currentGroups,
                localHosts: currentHosts,
                remoteRecords: context.remoteRecords,
                baseline: baseline,
                ownerUID: ownerUID,
                masterKey: masterKey
            )
            manualPlan = plan
            state = .ready(plan.preview)
            previewContext = PreviewContext(
                ownerUID: ownerUID,
                groups: currentGroups,
                hosts: currentHosts,
                remoteRecords: context.remoteRecords,
                baseline: baseline
            )
            return summary
        } catch {
            baselineState = .failed(error.localizedDescription)
            throw error
        }
    }

    func syncLocalChanges(
        projectID: String,
        ownerUID: String,
        idToken: String,
        currentGroups: [HostGroup],
        currentHosts: [HostProfile]
    ) {
        guard manualSyncTask == nil,
              let displayedPlan = manualPlan,
              let context = previewContext,
              let startingBaseline = context.baseline,
              context.ownerUID == ownerUID,
              context.groups == currentGroups,
              context.hosts == currentHosts else {
            manualSyncState = .failed(MetadataManualSyncError.planOutdated.localizedDescription)
            return
        }
        let total = displayedPlan.uploadCount + displayedPlan.repairCount
        guard total > 0 else {
            manualSyncState = .failed(MetadataManualSyncError.nothingToUpload.localizedDescription)
            return
        }
        manualSyncState = .syncing(completed: 0, total: total)
        manualSyncTask = Task { [weak self] in
            guard let self else { return }
            var completed = 0
            var uploaded = 0
            var repaired = 0
            do {
                guard let masterKey = try VaultMasterKeyStore.load(
                    ownerUID: ownerUID,
                    version: VaultCryptoFormat.masterKeyVersion
                ) else {
                    throw MetadataSyncPreviewError.missingMasterKey
                }
                let storedBaseline = try MetadataSyncBaselineStore().load(ownerUID: ownerUID)
                guard storedBaseline == startingBaseline else {
                    throw MetadataManualSyncError.planOutdated
                }
                let backend = FirestoreMetadataBackend(projectID: projectID)
                let latestRemote = try await backend.fetchAll(ownerUID: ownerUID, idToken: idToken)
                guard Self.sorted(latestRemote) == context.remoteRecords else {
                    throw MetadataManualSyncError.planOutdated
                }
                let latestPlan = try MetadataManualSyncPlanner.makePlan(
                    localGroups: currentGroups,
                    localHosts: currentHosts,
                    remoteRecords: latestRemote,
                    baseline: startingBaseline,
                    ownerUID: ownerUID,
                    masterKey: masterKey
                )
                guard latestPlan.items == displayedPlan.items else {
                    throw MetadataManualSyncError.planOutdated
                }
                guard latestPlan.canApplyLocalChanges else {
                    throw MetadataManualSyncError.blockedByRemoteChanges
                }

                let remoteByID = Dictionary(uniqueKeysWithValues: latestRemote.map { ($0.id, $0) })
                let groupByID = Dictionary(uniqueKeysWithValues: currentGroups.map { ($0.id, $0) })
                let hostByID = Dictionary(uniqueKeysWithValues: currentHosts.map { ($0.id, $0) })
                var baseline = startingBaseline
                let actions = latestPlan.items.filter {
                    $0.disposition == .uploadCreate
                        || $0.disposition == .uploadUpdate
                        || $0.disposition == .baselineRepair
                }.sorted { lhs, rhs in
                    if lhs.recordType != rhs.recordType { return lhs.recordType == .group }
                    return lhs.id.uuidString < rhs.id.uuidString
                }

                for action in actions {
                    guard !Task.isCancelled else { throw CancellationError() }
                    let localDigest: String
                    if let group = groupByID[action.id], action.recordType == .group {
                        localDigest = try MetadataSyncCodec.contentDigest(group: group)
                    } else if let host = hostByID[action.id], action.recordType == .host {
                        localDigest = try MetadataSyncCodec.contentDigest(host: host)
                    } else {
                        throw MetadataManualSyncError.planOutdated
                    }

                    let savedRecord: EncryptedSyncRecord
                    if action.disposition == .baselineRepair {
                        guard let remote = remoteByID[action.id] else {
                            throw MetadataManualSyncError.planOutdated
                        }
                        savedRecord = remote
                        repaired += 1
                    } else {
                        let revision: UInt64
                        if action.disposition == .uploadCreate {
                            revision = 1
                        } else {
                            guard let oldEntry = baseline.entries.first(where: { $0.recordID == action.id }) else {
                                throw MetadataManualSyncError.invalidBaseline
                            }
                            revision = oldEntry.remoteRevision + 1
                        }
                        let pending: EncryptedSyncRecord
                        if let group = groupByID[action.id], action.recordType == .group {
                            pending = try MetadataSyncCodec.encrypt(
                                group: group,
                                ownerUID: ownerUID,
                                masterKey: masterKey,
                                revision: revision,
                                modifiedByDeviceID: baseline.deviceID
                            )
                        } else if let host = hostByID[action.id], action.recordType == .host {
                            pending = try MetadataSyncCodec.encrypt(
                                host: host,
                                ownerUID: ownerUID,
                                masterKey: masterKey,
                                revision: revision,
                                modifiedByDeviceID: baseline.deviceID
                            )
                        } else {
                            throw MetadataManualSyncError.planOutdated
                        }
                        if action.disposition == .uploadCreate {
                            savedRecord = try await backend.create(pending, ownerUID: ownerUID, idToken: idToken)
                        } else {
                            savedRecord = try await backend.upsert(pending, ownerUID: ownerUID, idToken: idToken)
                        }
                        uploaded += 1
                    }

                    guard savedRecord.id == action.id,
                          savedRecord.recordType == action.recordType,
                          savedRecord.modifiedByDeviceID == baseline.deviceID else {
                        throw MetadataManualSyncError.verificationFailed
                    }
                    let decryptedDigest: String
                    switch try MetadataSyncCodec.decrypt(savedRecord, ownerUID: ownerUID, masterKey: masterKey) {
                    case .group(let group): decryptedDigest = try MetadataSyncCodec.contentDigest(group: group)
                    case .host(let host): decryptedDigest = try MetadataSyncCodec.contentDigest(host: host)
                    case .tombstone: throw MetadataManualSyncError.verificationFailed
                    }
                    guard decryptedDigest == localDigest else {
                        throw MetadataManualSyncError.verificationFailed
                    }
                    let entry = MetadataSyncBaselineEntry(
                        recordID: action.id,
                        recordType: action.recordType,
                        remoteRevision: savedRecord.revision,
                        localContentDigest: localDigest,
                        remoteRecordDigest: try MetadataSyncCodec.encryptedRecordDigest(savedRecord)
                    )
                    baseline = MetadataSyncBaselinePlanner.replacingEntry(entry, in: baseline)
                    try MetadataSyncBaselineStore().save(baseline, ownerUID: ownerUID)
                    completed += 1
                    self.baselineState = .ready(MetadataSyncBaselinePlanner.summary(baseline))
                    self.manualSyncState = .syncing(completed: completed, total: total)
                }

                let verifiedRemote = try await backend.fetchAll(ownerUID: ownerUID, idToken: idToken)
                let verifiedPlan = try MetadataManualSyncPlanner.makePlan(
                    localGroups: currentGroups,
                    localHosts: currentHosts,
                    remoteRecords: verifiedRemote,
                    baseline: baseline,
                    ownerUID: ownerUID,
                    masterKey: masterKey
                )
                guard verifiedPlan.uploadCount == 0,
                      verifiedPlan.repairCount == 0,
                      verifiedPlan.downloadCount == 0,
                      verifiedPlan.conflictCount == 0,
                      verifiedPlan.unchangedCount == currentGroups.count + currentHosts.count else {
                    throw MetadataManualSyncError.verificationFailed
                }
                self.manualPlan = verifiedPlan
                self.state = .ready(verifiedPlan.preview)
                self.previewContext = PreviewContext(
                    ownerUID: ownerUID,
                    groups: currentGroups,
                    hosts: currentHosts,
                    remoteRecords: Self.sorted(verifiedRemote),
                    baseline: baseline
                )
                self.manualSyncState = .completed(uploaded: uploaded, repaired: repaired)
            } catch is CancellationError {
                self.manualSyncState = .idle
            } catch {
                let prefix = completed > 0 ? "已安全完成 \(completed) 筆後停止。" : ""
                self.manualSyncState = .failed(prefix + error.localizedDescription)
            }
            self.manualSyncTask = nil
        }
    }

    func verifiedRemoteMerge(
        projectID: String,
        ownerUID: String,
        idToken: String,
        currentGroups: [HostGroup],
        currentHosts: [HostProfile]
    ) async throws -> MetadataManualDownloadResult {
        guard let displayedPlan = manualPlan,
              displayedPlan.canApplyRemoteChanges,
              let context = previewContext,
              let startingBaseline = context.baseline,
              context.ownerUID == ownerUID,
              context.groups == currentGroups,
              context.hosts == currentHosts else {
            throw MetadataManualSyncError.planOutdated
        }
        manualDownloadState = .downloading
        do {
            guard let masterKey = try VaultMasterKeyStore.load(
                ownerUID: ownerUID,
                version: VaultCryptoFormat.masterKeyVersion
            ) else {
                throw MetadataSyncPreviewError.missingMasterKey
            }
            guard try MetadataSyncBaselineStore().load(ownerUID: ownerUID) == startingBaseline else {
                throw MetadataManualSyncError.planOutdated
            }
            let backend = FirestoreMetadataBackend(projectID: projectID)
            let latestRemote = try await backend.fetchAll(ownerUID: ownerUID, idToken: idToken)
            guard Self.sorted(latestRemote) == context.remoteRecords else {
                throw MetadataManualSyncError.planOutdated
            }
            let latestPlan = try MetadataManualSyncPlanner.makePlan(
                localGroups: currentGroups,
                localHosts: currentHosts,
                remoteRecords: latestRemote,
                baseline: startingBaseline,
                ownerUID: ownerUID,
                masterKey: masterKey
            )
            guard latestPlan.items == displayedPlan.items,
                  latestPlan.canApplyRemoteChanges else {
                throw MetadataManualSyncError.planOutdated
            }
            return try MetadataManualDownloadPlanner.makeResult(
                localGroups: currentGroups,
                localHosts: currentHosts,
                remoteRecords: latestRemote,
                baseline: startingBaseline,
                plan: latestPlan,
                ownerUID: ownerUID,
                masterKey: masterKey
            )
        } catch {
            manualDownloadState = .failed(error.localizedDescription)
            throw error
        }
    }

    func commitRemoteMerge(
        _ result: MetadataManualDownloadResult,
        ownerUID: String,
        currentGroups: [HostGroup],
        currentHosts: [HostProfile]
    ) throws {
        do {
            guard Set(currentGroups) == Set(result.document.groups),
                  Set(currentHosts) == Set(result.document.hosts) else {
                throw MetadataManualSyncError.verificationFailed
            }
            guard let masterKey = try VaultMasterKeyStore.load(
                ownerUID: ownerUID,
                version: VaultCryptoFormat.masterKeyVersion
            ) else {
                throw MetadataSyncPreviewError.missingMasterKey
            }
            try MetadataSyncBaselineStore().save(result.baseline, ownerUID: ownerUID)
            let verifiedPlan = try MetadataManualSyncPlanner.makePlan(
                localGroups: currentGroups,
                localHosts: currentHosts,
                remoteRecords: result.remoteRecords,
                baseline: result.baseline,
                ownerUID: ownerUID,
                masterKey: masterKey
            )
            guard verifiedPlan.uploadCount == 0,
                  verifiedPlan.repairCount == 0,
                  verifiedPlan.downloadCount == 0,
                  verifiedPlan.conflictCount == 0,
                  verifiedPlan.unchangedCount == currentGroups.count + currentHosts.count else {
                throw MetadataManualSyncError.verificationFailed
            }
            baselineState = .ready(MetadataSyncBaselinePlanner.summary(result.baseline))
            manualPlan = verifiedPlan
            state = .ready(verifiedPlan.preview)
            previewContext = PreviewContext(
                ownerUID: ownerUID,
                groups: currentGroups,
                hosts: currentHosts,
                remoteRecords: result.remoteRecords,
                baseline: result.baseline
            )
            manualDownloadState = .completed(downloaded: result.downloadedCount)
        } catch {
            manualDownloadState = .failed(error.localizedDescription)
            throw error
        }
    }

    func reset() {
        previewTask?.cancel()
        initializationTask?.cancel()
        manualSyncTask?.cancel()
        previewTask = nil
        initializationTask = nil
        manualSyncTask = nil
        previewContext = nil
        state = .idle
        initializationState = .idle
        baselineState = .idle
        manualPlan = nil
        manualSyncState = .idle
        manualDownloadState = .idle
    }

    private struct PreviewContext {
        let ownerUID: String
        let groups: [HostGroup]
        let hosts: [HostProfile]
        let remoteRecords: [EncryptedSyncRecord]
        let baseline: MetadataSyncBaseline?
    }

    private static func sorted(_ records: [EncryptedSyncRecord]) -> [EncryptedSyncRecord] {
        records.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

private enum LocalMetadataValue {
    case group(HostGroup)
    case host(HostProfile)

    var recordType: SyncRecordType {
        switch self {
        case .group: .group
        case .host: .host
        }
    }

    var displayName: String {
        switch self {
        case .group(let group): group.name
        case .host(let host): host.displayName
        }
    }
}

private enum RemoteMetadataValue {
    case group(HostGroup, EncryptedSyncRecord)
    case host(HostProfile, EncryptedSyncRecord)
    case tombstone(SyncRecordType, EncryptedSyncRecord)

    var record: EncryptedSyncRecord {
        switch self {
        case .group(_, let record), .host(_, let record), .tombstone(_, let record): record
        }
    }
}
