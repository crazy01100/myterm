import Foundation

enum MetadataManualSyncDisposition: String, Equatable, Sendable {
    case uploadCreate
    case uploadUpdate
    case baselineRepair
    case download
    case remoteDeletion
    case localDeletion
    case conflict
    case unchanged
}

struct MetadataManualSyncItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let recordType: SyncRecordType
    let displayName: String
    let disposition: MetadataManualSyncDisposition
    let detail: String
    let remoteRevision: UInt64?
}

struct MetadataManualSyncPlan: Equatable, Sendable {
    let generatedAt: Date
    let localGroupCount: Int
    let localHostCount: Int
    let remoteGroupCount: Int
    let remoteHostCount: Int
    let items: [MetadataManualSyncItem]

    var uploadCount: Int {
        items.count { $0.disposition == .uploadCreate || $0.disposition == .uploadUpdate }
    }
    var repairCount: Int { items.count { $0.disposition == .baselineRepair } }
    var downloadCount: Int { items.count { $0.disposition == .download }
    }
    var deletionCount: Int { items.count { $0.disposition == .remoteDeletion || $0.disposition == .localDeletion } }
    var conflictCount: Int {
        items.count { $0.disposition == .conflict || $0.disposition == .remoteDeletion || $0.disposition == .localDeletion }
    }
    var unchangedCount: Int { items.count { $0.disposition == .unchanged } }
    var canApplyLocalChanges: Bool {
        uploadCount + repairCount > 0 && downloadCount == 0 && conflictCount == 0
    }
    var canApplyRemoteChanges: Bool {
        downloadCount > 0 && uploadCount == 0 && repairCount == 0 && conflictCount == 0
    }

    var preview: MetadataSyncPreview {
        MetadataSyncPreview(
            generatedAt: generatedAt,
            localGroupCount: localGroupCount,
            localHostCount: localHostCount,
            remoteGroupCount: remoteGroupCount,
            remoteHostCount: remoteHostCount,
            items: items.map { item in
                let disposition: MetadataSyncPreviewDisposition
                switch item.disposition {
                case .uploadCreate, .uploadUpdate: disposition = .upload
                case .download: disposition = .download
                case .conflict, .remoteDeletion, .localDeletion: disposition = .conflict
                case .baselineRepair, .unchanged: disposition = .unchanged
                }
                return MetadataSyncPreviewItem(
                    id: item.id,
                    recordType: item.recordType,
                    displayName: item.displayName,
                    disposition: disposition,
                    detail: item.detail,
                    remoteRevision: item.remoteRevision
                )
            }
        )
    }
}

enum MetadataManualSyncError: LocalizedError, Equatable {
    case missingBaseline
    case invalidBaseline
    case duplicateIdentity
    case planOutdated
    case blockedByRemoteChanges
    case nothingToUpload
    case nothingToDownload
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .missingBaseline: "這台 Mac 尚未建立同步基線。"
        case .invalidBaseline: "同步基線與目前帳號或主機資料不一致。"
        case .duplicateIdentity: "同步資料含有重複識別碼，已停止操作。"
        case .planOutdated: "資料已在預覽後改變，請重新整理再同步。"
        case .blockedByRemoteChanges: "雲端也有變更、下載或刪除項目，已停止上傳以避免覆蓋。"
        case .nothingToUpload: "目前沒有可安全上傳的本機變更。"
        case .nothingToDownload: "目前沒有可安全下載的雲端變更。"
        case .verificationFailed: "上傳後重新下載驗證失敗；已停止後續操作。"
        }
    }
}

enum MetadataManualSyncPlanner {
    static func makePlan(
        localGroups: [HostGroup],
        localHosts: [HostProfile],
        remoteRecords: [EncryptedSyncRecord],
        baseline: MetadataSyncBaseline,
        ownerUID: String,
        masterKey: VaultMasterKey,
        generatedAt: Date = .now
    ) throws -> MetadataManualSyncPlan {
        guard baseline.schemaVersion == MetadataSyncBaselineStore.schemaVersion,
              baseline.ownerUIDDigest == MetadataSyncBaselineStore.ownerDigest(ownerUID) else {
            throw MetadataManualSyncError.invalidBaseline
        }
        var local: [UUID: ManualLocalValue] = [:]
        for group in localGroups {
            guard local[group.id] == nil else { throw MetadataManualSyncError.duplicateIdentity }
            local[group.id] = .group(group, try MetadataSyncCodec.contentDigest(group: group))
        }
        for host in localHosts {
            guard local[host.id] == nil else { throw MetadataManualSyncError.duplicateIdentity }
            local[host.id] = .host(host, try MetadataSyncCodec.contentDigest(host: host))
        }
        var remote: [UUID: ManualRemoteValue] = [:]
        for record in remoteRecords {
            guard remote[record.id] == nil else { throw MetadataManualSyncError.duplicateIdentity }
            let recordDigest = try MetadataSyncCodec.encryptedRecordDigest(record)
            switch try MetadataSyncCodec.decrypt(record, ownerUID: ownerUID, masterKey: masterKey) {
            case .group(let group):
                remote[record.id] = .group(
                    group,
                    record,
                    try MetadataSyncCodec.contentDigest(group: group),
                    recordDigest
                )
            case .host(let host):
                remote[record.id] = .host(
                    host,
                    record,
                    try MetadataSyncCodec.contentDigest(host: host),
                    recordDigest
                )
            case .tombstone:
                remote[record.id] = .tombstone(record, recordDigest)
            }
        }
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.entries.map { ($0.recordID, $0) })
        guard baselineByID.count == baseline.entries.count else {
            throw MetadataManualSyncError.invalidBaseline
        }
        let allIDs = Set(local.keys).union(remote.keys).union(baselineByID.keys)
        let items = try allIDs.map { id in
            try makeItem(
                id: id,
                local: local[id],
                remote: remote[id],
                baseline: baselineByID[id],
                deviceID: baseline.deviceID
            )
        }.sorted(by: itemOrder)
        return MetadataManualSyncPlan(
            generatedAt: generatedAt,
            localGroupCount: localGroups.count,
            localHostCount: localHosts.count,
            remoteGroupCount: remote.values.count { $0.recordType == .group && !$0.deleted },
            remoteHostCount: remote.values.count { $0.recordType == .host && !$0.deleted },
            items: items
        )
    }

    private static func makeItem(
        id: UUID,
        local: ManualLocalValue?,
        remote: ManualRemoteValue?,
        baseline: MetadataSyncBaselineEntry?,
        deviceID: UUID
    ) throws -> MetadataManualSyncItem {
        guard let baseline else {
            switch (local, remote) {
            case (.some(let local), nil):
                return item(id, local.recordType, local.displayName, .uploadCreate, "本機新增；雲端尚無此識別碼。", nil)
            case (nil, .some(let remote)):
                return item(
                    id,
                    remote.recordType,
                    remote.displayName,
                    remote.deleted ? .remoteDeletion : .download,
                    remote.deleted ? "雲端只有刪除標記；目前不會套用。" : "雲端新增，可安全下載合併。",
                    remote.record.revision
                )
            case (.some(let local), .some(let remote)):
                return item(id, local.recordType, local.displayName, .conflict, "這筆資料不在基線中，但兩端同時存在。", remote.record.revision)
            case (nil, nil):
                throw MetadataManualSyncError.invalidBaseline
            }
        }
        guard baseline.recordType == local?.recordType ?? baseline.recordType,
              baseline.recordType == remote?.recordType ?? baseline.recordType else {
            return item(
                id,
                local?.recordType ?? remote?.recordType ?? baseline.recordType,
                local?.displayName ?? remote?.displayName ?? id.uuidString,
                .conflict,
                "資料類型與同步基線不一致。",
                remote?.record.revision
            )
        }
        guard let local else {
            return item(
                id, baseline.recordType, remote?.displayName ?? "已從本機刪除的紀錄", .localDeletion,
                "本機已刪除；tombstone 同步尚未開放。", remote?.record.revision
            )
        }
        guard let remote else {
            return item(id, local.recordType, local.displayName, .conflict, "雲端缺少基線中的紀錄。", nil)
        }
        let localSame = local.contentDigest == baseline.localContentDigest
        let remoteSame = remote.record.revision == baseline.remoteRevision
            && remote.recordDigest == baseline.remoteRecordDigest
        if localSame && remoteSame {
            return item(id, local.recordType, local.displayName, .unchanged, "本機與雲端都等於同步基線。", remote.record.revision)
        }
        if !localSame && remoteSame {
            return item(id, local.recordType, local.displayName, .uploadUpdate, "只有本機修改，可安全上傳 revision \(baseline.remoteRevision + 1)。", remote.record.revision)
        }
        if localSame && !remoteSame {
            return item(
                id,
                local.recordType,
                local.displayName,
                remote.deleted ? .remoteDeletion : .download,
                remote.deleted ? "雲端已刪除此筆；刪除同步尚未開放。" : "只有雲端改變，可先備份再安全套用。",
                remote.record.revision
            )
        }
        if !remote.deleted,
           remote.record.revision > baseline.remoteRevision,
           remote.contentDigest == local.contentDigest {
            let detail = remote.record.modifiedByDeviceID == deviceID
                ? "先前上傳已成功，只需修復這台 Mac 的本機基線。"
                : "兩端內容已一致，只需安全更新這台 Mac 的同步基線。"
            return item(id, local.recordType, local.displayName, .baselineRepair, detail, remote.record.revision)
        }
        return item(id, local.recordType, local.displayName, .conflict, "本機與雲端都在基線後改變，不會自動覆蓋。", remote.record.revision)
    }

    private static func item(
        _ id: UUID,
        _ type: SyncRecordType,
        _ name: String,
        _ disposition: MetadataManualSyncDisposition,
        _ detail: String,
        _ revision: UInt64?
    ) -> MetadataManualSyncItem {
        MetadataManualSyncItem(
            id: id,
            recordType: type,
            displayName: name.isEmpty ? id.uuidString : name,
            disposition: disposition,
            detail: detail,
            remoteRevision: revision
        )
    }

    private static func itemOrder(_ lhs: MetadataManualSyncItem, _ rhs: MetadataManualSyncItem) -> Bool {
        func rank(_ value: MetadataManualSyncDisposition) -> Int {
            switch value {
            case .conflict, .remoteDeletion, .localDeletion: 0
            case .uploadCreate, .uploadUpdate: 1
            case .baselineRepair: 2
            case .download: 3
            case .unchanged: 4
            }
        }
        let lhsRank = rank(lhs.disposition)
        let rhsRank = rank(rhs.disposition)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}

struct MetadataManualDownloadResult {
    let document: InventoryDocument
    let baseline: MetadataSyncBaseline
    let remoteRecords: [EncryptedSyncRecord]
    let downloadedCount: Int
}

enum MetadataManualDownloadPlanner {
    static func makeResult(
        localGroups: [HostGroup],
        localHosts: [HostProfile],
        remoteRecords: [EncryptedSyncRecord],
        baseline: MetadataSyncBaseline,
        plan: MetadataManualSyncPlan,
        ownerUID: String,
        masterKey: VaultMasterKey
    ) throws -> MetadataManualDownloadResult {
        guard plan.canApplyRemoteChanges else {
            throw MetadataManualSyncError.blockedByRemoteChanges
        }
        let downloadIDs = Set(plan.items.filter { $0.disposition == .download }.map(\.id))
        guard !downloadIDs.isEmpty else { throw MetadataManualSyncError.nothingToDownload }
        var groups = Dictionary(uniqueKeysWithValues: localGroups.map { ($0.id, $0) })
        var hosts = Dictionary(uniqueKeysWithValues: localHosts.map { ($0.id, $0) })
        var updatedBaseline = baseline
        var applied: Set<UUID> = []

        for record in remoteRecords where downloadIDs.contains(record.id) {
            guard !record.deleted else { throw MetadataManualSyncError.blockedByRemoteChanges }
            let localDigest: String
            switch try MetadataSyncCodec.decrypt(record, ownerUID: ownerUID, masterKey: masterKey) {
            case .group(let group):
                guard record.recordType == .group else { throw MetadataManualSyncError.verificationFailed }
                groups[group.id] = group
                localDigest = try MetadataSyncCodec.contentDigest(group: group)
            case .host(var host):
                guard record.recordType == .host else { throw MetadataManualSyncError.verificationFailed }
                if host.authenticationMethod == .privateKey,
                   let existingPath = hosts[host.id]?.privateKeyPath,
                   !existingPath.isEmpty {
                    host.privateKeyPath = existingPath
                }
                hosts[host.id] = host
                localDigest = try MetadataSyncCodec.contentDigest(host: host)
            case .tombstone:
                throw MetadataManualSyncError.blockedByRemoteChanges
            }
            let entry = MetadataSyncBaselineEntry(
                recordID: record.id,
                recordType: record.recordType,
                remoteRevision: record.revision,
                localContentDigest: localDigest,
                remoteRecordDigest: try MetadataSyncCodec.encryptedRecordDigest(record)
            )
            updatedBaseline = MetadataSyncBaselinePlanner.replacingEntry(entry, in: updatedBaseline)
            applied.insert(record.id)
        }
        guard applied == downloadIDs else { throw MetadataManualSyncError.verificationFailed }
        let document = InventoryDocument(
            groups: Array(groups.values),
            hosts: Array(hosts.values)
        )
        try MetadataMergedInventoryValidator.validate(document)
        return MetadataManualDownloadResult(
            document: document,
            baseline: updatedBaseline,
            remoteRecords: remoteRecords.sorted { $0.id.uuidString < $1.id.uuidString },
            downloadedCount: applied.count
        )
    }
}

enum MetadataMergedInventoryValidator {
    static func validate(_ document: InventoryDocument) throws {
        guard document.groups.count + document.hosts.count <= MetadataSyncPreviewPlanner.maximumRecordCount else {
            throw MetadataSyncPreviewError.tooManyRecords
        }
        var allIDs: Set<UUID> = []
        guard document.groups.allSatisfy({ allIDs.insert($0.id).inserted }),
              document.hosts.allSatisfy({ allIDs.insert($0.id).inserted }) else {
            throw CloudInventoryRestoreError.invalidInventory
        }
        let groupsByID = Dictionary(uniqueKeysWithValues: document.groups.map { ($0.id, $0) })
        for group in document.groups {
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != "未分類", name.count <= 512 else {
                throw CloudInventoryRestoreError.invalidInventory
            }
            if let parentID = group.parentID, groupsByID[parentID] == nil {
                throw CloudInventoryRestoreError.invalidInventory
            }
            var visited: Set<UUID> = [group.id]
            var current = group.parentID
            while let id = current {
                guard visited.insert(id).inserted else { throw CloudInventoryRestoreError.invalidInventory }
                current = groupsByID[id]?.parentID
            }
        }
        for (index, group) in document.groups.enumerated() {
            guard !document.groups.dropFirst(index + 1).contains(where: {
                $0.parentID == group.parentID
                    && $0.name.localizedCaseInsensitiveCompare(group.name) == .orderedSame
            }) else {
                throw CloudInventoryRestoreError.invalidInventory
            }
        }
        for host in document.hosts {
            guard host.groupID.map({ groupsByID[$0] != nil }) ?? true else {
                throw CloudInventoryRestoreError.invalidInventory
            }
            var candidate = host
            if candidate.authenticationMethod == .privateKey && candidate.privateKeyPath.isEmpty {
                candidate.privateKeyPath = "/MyTerm/local-private-key-required"
            }
            guard (try? candidate.validated()) != nil else {
                throw CloudInventoryRestoreError.invalidInventory
            }
        }
    }
}

private enum ManualLocalValue {
    case group(HostGroup, String)
    case host(HostProfile, String)

    var recordType: SyncRecordType {
        switch self { case .group: .group; case .host: .host }
    }
    var displayName: String {
        switch self { case .group(let value, _): value.name; case .host(let value, _): value.displayName }
    }
    var contentDigest: String {
        switch self { case .group(_, let digest), .host(_, let digest): digest }
    }
}

private enum ManualRemoteValue {
    case group(HostGroup, EncryptedSyncRecord, String, String)
    case host(HostProfile, EncryptedSyncRecord, String, String)
    case tombstone(EncryptedSyncRecord, String)

    var record: EncryptedSyncRecord {
        switch self {
        case .group(_, let record, _, _), .host(_, let record, _, _), .tombstone(let record, _): record
        }
    }
    var recordType: SyncRecordType { record.recordType }
    var deleted: Bool { record.deleted }
    var displayName: String {
        switch self {
        case .group(let value, _, _, _): value.name
        case .host(let value, _, _, _): value.displayName
        case .tombstone: "雲端刪除紀錄"
        }
    }
    var contentDigest: String? {
        switch self {
        case .group(_, _, let digest, _), .host(_, _, let digest, _): digest
        case .tombstone: nil
        }
    }
    var recordDigest: String {
        switch self {
        case .group(_, _, _, let digest), .host(_, _, _, let digest), .tombstone(_, let digest): digest
        }
    }
}
