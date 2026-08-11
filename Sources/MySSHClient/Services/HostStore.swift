import Foundation
import Security

enum GroupStoreError: LocalizedError, Equatable {
    case emptyName
    case duplicateName
    case missingGroup
    case invalidParent
    case cyclicParent

    var errorDescription: String? {
        switch self {
        case .emptyName: "請輸入群組名稱。"
        case .duplicateName: "同一層已經有同名群組。"
        case .missingGroup: "找不到指定的群組。"
        case .invalidParent: "找不到指定的上層群組。"
        case .cyclicParent: "群組不能放進自己或自己的子群組。"
        }
    }
}

struct HostGroupChoice: Identifiable, Hashable {
    let group: HostGroup
    let depth: Int
    let path: String

    var id: HostGroup.ID { group.id }
}

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [HostProfile] = []
    @Published private(set) var groups: [HostGroup] = []
    @Published var selectedHostID: HostProfile.ID?
    @Published var lastError: String?
    @Published var lastNotice: String?

    init() {
        do {
            try AppPaths.prepare()
            try load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func save(_ profile: HostProfile, password: String?) throws {
        var profile = try profile.validated()
        if let groupID = profile.groupID, !groups.contains(where: { $0.id == groupID }) {
            profile.groupID = nil
        }
        if let password, !password.isEmpty {
            guard !profile.username.isEmpty else { throw HostValidationError.invalidUsername }
            try KeychainStore.save(password: password, for: profile.id)
        }
        if let index = hosts.firstIndex(where: { $0.id == profile.id }) {
            hosts[index] = profile
        } else {
            hosts.append(profile)
        }
        sortInventory()
        try persist()
        selectedHostID = profile.id
    }

    func delete(_ profile: HostProfile) throws {
        let previousHosts = hosts
        let previousSelection = selectedHostID
        hosts.removeAll { $0.id == profile.id }
        if selectedHostID == profile.id { selectedHostID = nil }
        do {
            try persist()
        } catch {
            hosts = previousHosts
            selectedHostID = previousSelection
            throw error
        }

        do {
            let result = try KeychainStore.deletePassword(for: profile.id)
            if case .manualCleanupRequired(let status) = result {
                lastNotice = manualKeychainCleanupMessage(for: profile, status: status)
            }
        } catch {
            lastNotice = "主機已刪除，但其舊密碼無法自動從 Keychain 移除。請在「鑰匙圈存取」搜尋服務名稱 tw.local.MySSHClient.host-password，並移除帳號 \(profile.id.uuidString)。原因：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func createGroup(named name: String, parentID: HostGroup.ID? = nil) throws -> HostGroup {
        try validateParent(parentID, for: nil)
        let name = try validatedGroupName(name, parentID: parentID)
        let group = HostGroup(name: name, parentID: parentID)
        groups.append(group)
        sortInventory()
        try persist()
        return group
    }

    func updateGroup(_ group: HostGroup, name: String, parentID: HostGroup.ID?) throws {
        try validateParent(parentID, for: group.id)
        let name = try validatedGroupName(name, parentID: parentID, excluding: group.id)
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else {
            throw GroupStoreError.missingGroup
        }
        groups[index].name = name
        groups[index].parentID = parentID
        sortInventory()
        try persist()
    }

    func renameGroup(_ group: HostGroup, to name: String) throws {
        try updateGroup(group, name: name, parentID: group.parentID)
    }

    /// Deleting a group never deletes hosts or descendants. Direct contents
    /// are promoted to the deleted group's parent.
    func deleteGroup(_ group: HostGroup) throws {
        guard groups.contains(where: { $0.id == group.id }) else {
            throw GroupStoreError.missingGroup
        }
        for index in hosts.indices where hosts[index].groupID == group.id {
            hosts[index].groupID = group.parentID
            hosts[index].updatedAt = .now
        }
        for index in groups.indices where groups[index].parentID == group.id {
            groups[index].parentID = group.parentID
        }
        groups.removeAll { $0.id == group.id }
        sortInventory()
        try persist()
    }

    func profile(id: UUID?) -> HostProfile? {
        guard let id else { return nil }
        return hosts.first { $0.id == id }
    }

    func group(id: UUID?) -> HostGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    func groupName(for host: HostProfile) -> String {
        host.groupID.map(groupPath(for:)) ?? "未分類"
    }

    func childGroups(of parentID: HostGroup.ID?) -> [HostGroup] {
        groups
            .filter { $0.parentID == parentID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func descendantGroupIDs(of groupID: HostGroup.ID, includingSelf: Bool = true) -> Set<HostGroup.ID> {
        var result: Set<HostGroup.ID> = includingSelf ? [groupID] : []
        var pending = childGroups(of: groupID).map(\.id)
        while let current = pending.popLast() {
            guard result.insert(current).inserted else { continue }
            pending.append(contentsOf: childGroups(of: current).map(\.id))
        }
        return result
    }

    func hostCount(in groupID: HostGroup.ID, includingDescendants: Bool = true) -> Int {
        let groupIDs = includingDescendants
            ? descendantGroupIDs(of: groupID)
            : Set([groupID])
        return hosts.count { host in
            host.groupID.map(groupIDs.contains) == true
        }
    }

    func groupPath(for groupID: HostGroup.ID) -> String {
        groupAncestry(for: groupID).map(\.name).joined(separator: " / ")
    }

    func groupAncestry(for groupID: HostGroup.ID) -> [HostGroup] {
        var groups: [HostGroup] = []
        var currentID: HostGroup.ID? = groupID
        var visited: Set<HostGroup.ID> = []
        while let id = currentID, visited.insert(id).inserted, let current = group(id: id) {
            groups.append(current)
            currentID = current.parentID
        }
        return groups.reversed()
    }

    func groupChoices(excludingSubtreeOf excludedID: HostGroup.ID? = nil) -> [HostGroupChoice] {
        let excludedIDs = excludedID.map { descendantGroupIDs(of: $0) } ?? []
        func choices(parentID: HostGroup.ID?, depth: Int, prefix: String) -> [HostGroupChoice] {
            childGroups(of: parentID).flatMap { group -> [HostGroupChoice] in
                guard !excludedIDs.contains(group.id) else { return [] }
                let path = prefix.isEmpty ? group.name : "\(prefix) / \(group.name)"
                return [HostGroupChoice(group: group, depth: depth, path: path)]
                    + choices(parentID: group.id, depth: depth + 1, prefix: path)
            }
        }
        return choices(parentID: nil, depth: 0, prefix: "")
    }

    func recordDetectedPlatform(_ platform: HostPlatform, for hostID: HostProfile.ID) throws {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        // Strong evidence is recorded once. Avoid silently replacing a
        // previously identified platform because of later ambiguous output.
        guard hosts[index].detectedPlatform == nil else { return }
        hosts[index].detectedPlatform = platform
        hosts[index].updatedAt = .now
        try persist()
    }

    func previewImport(
        _ payload: HostImportPayload,
        duplicatePolicy: HostImportDuplicatePolicy
    ) throws -> HostImportMergeResult {
        try HostTransferService.merge(
            existing: InventoryDocument(groups: groups, hosts: hosts),
            payload: payload,
            duplicatePolicy: duplicatePolicy
        )
    }

    @discardableResult
    func applyImport(
        _ payload: HostImportPayload,
        duplicatePolicy: HostImportDuplicatePolicy
    ) throws -> HostImportApplicationResult {
        let merge = try previewImport(payload, duplicatePolicy: duplicatePolicy)
        guard merge.importedHostCount > 0 || merge.addedGroupCount > 0 else {
            throw HostTransferError.noImportableHosts
        }

        let previousHosts = hosts
        let previousGroups = groups
        let previousSelection = selectedHostID
        let backupURL = try createImportBackup()
        hosts = merge.document.hosts
        groups = merge.document.groups
        sanitizeReferences()
        sortInventory()
        do {
            try persist()
        } catch {
            hosts = previousHosts
            groups = previousGroups
            selectedHostID = previousSelection
            throw error
        }
        lastNotice = "已匯入 \(merge.importedHostCount) 台主機與 \(merge.addedGroupCount) 個群組。匯入前資料已備份。"
        return HostImportApplicationResult(merge: merge, backupURL: backupURL)
    }

    func exportTransferData() throws -> Data {
        try HostTransferService.exportData(groups: groups, hosts: hosts)
    }

    @discardableResult
    func restoreEmptyInventoryFromCloud(_ document: InventoryDocument) throws -> URL {
        guard groups.isEmpty, hosts.isEmpty else {
            throw CloudInventoryRestoreError.localInventoryNotEmpty
        }
        try CloudInventoryRestoreValidator.validate(document)
        let backupURL = try createSyncRestoreBackup()
        let previousGroups = groups
        let previousHosts = hosts
        let previousSelection = selectedHostID
        groups = document.groups
        hosts = document.hosts
        sortInventory()
        do {
            try persist()
        } catch {
            groups = previousGroups
            hosts = previousHosts
            selectedHostID = previousSelection
            throw error
        }
        lastNotice = "已從端對端加密同步還原 \(hosts.count) 台主機與 \(groups.count) 個群組；還原前資料已備份。"
        return backupURL
    }

    @discardableResult
    func applyVerifiedCloudMerge(_ document: InventoryDocument) throws -> URL {
        try MetadataMergedInventoryValidator.validate(document)
        let backupURL = try createSyncRestoreBackup()
        let previousGroups = groups
        let previousHosts = hosts
        let previousSelection = selectedHostID
        let incomingHostIDs = Set(document.hosts.map(\.id))
        let removedHosts = previousHosts.filter { !incomingHostIDs.contains($0.id) }
        groups = document.groups
        hosts = document.hosts
        sortInventory()
        if let selectedHostID, !hosts.contains(where: { $0.id == selectedHostID }) {
            self.selectedHostID = nil
        }
        do {
            try persist()
        } catch {
            groups = previousGroups
            hosts = previousHosts
            selectedHostID = previousSelection
            throw error
        }
        var cleanupNotices: [String] = []
        for profile in removedHosts {
            do {
                let result = try KeychainStore.deletePassword(for: profile.id)
                if case .manualCleanupRequired(let status) = result {
                    cleanupNotices.append(manualKeychainCleanupMessage(for: profile, status: status))
                }
            } catch {
                cleanupNotices.append(
                    "已同步刪除主機 \(profile.displayName)，但其舊密碼無法自動從 Keychain 移除：\(error.localizedDescription)"
                )
            }
        }
        lastNotice = (["已從端對端加密同步套用雲端變更；套用前資料已備份。"] + cleanupNotices)
            .joined(separator: "\n")
        return backupURL
    }

    private func validatedGroupName(
        _ input: String,
        parentID: HostGroup.ID?,
        excluding excludedID: UUID? = nil
    ) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GroupStoreError.emptyName }
        guard name != "未分類" else { throw GroupStoreError.duplicateName }
        let duplicate = groups.contains {
            $0.id != excludedID &&
            $0.parentID == parentID &&
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        guard !duplicate else { throw GroupStoreError.duplicateName }
        return name
    }

    private func validateParent(_ parentID: HostGroup.ID?, for groupID: HostGroup.ID?) throws {
        guard let parentID else { return }
        guard groups.contains(where: { $0.id == parentID }) else {
            throw GroupStoreError.invalidParent
        }
        guard let groupID else { return }
        guard parentID != groupID,
              !descendantGroupIDs(of: groupID, includingSelf: false).contains(parentID) else {
            throw GroupStoreError.cyclicParent
        }
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: AppPaths.hostsFile.path) else { return }
        let data = try Data(contentsOf: AppPaths.hostsFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let document = try? decoder.decode(InventoryDocument.self, from: data) {
            groups = document.groups
            hosts = document.hosts
            sanitizeReferences()
            sortInventory()
            if document.schemaVersion < InventoryDocument.currentSchemaVersion {
                try backupPreHierarchyInventoryIfNeeded()
                try persist()
            }
            return
        }

        let legacyHosts = try decoder.decode([HostProfile].self, from: data)
        let document = InventoryDocument.migrating(legacyHosts)
        groups = document.groups
        hosts = document.hosts
        try backupLegacyInventoryIfNeeded()
        sortInventory()
        try persist()
    }

    private func backupLegacyInventoryIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: AppPaths.legacyHostsBackupFile.path) else { return }
        try FileManager.default.copyItem(at: AppPaths.hostsFile, to: AppPaths.legacyHostsBackupFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: AppPaths.legacyHostsBackupFile.path
        )
    }

    private func backupPreHierarchyInventoryIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: AppPaths.preHierarchyBackupFile.path) else { return }
        try FileManager.default.copyItem(at: AppPaths.hostsFile, to: AppPaths.preHierarchyBackupFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: AppPaths.preHierarchyBackupFile.path
        )
    }

    private func createImportBackup() throws -> URL {
        try FileManager.default.createDirectory(
            at: AppPaths.importBackupsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backupURL = AppPaths.importBackupsDirectory
            .appending(path: "hosts-before-import-\(formatter.string(from: .now)).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(InventoryDocument(groups: groups, hosts: hosts))
        try data.write(to: backupURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        return backupURL
    }

    private func createSyncRestoreBackup() throws -> URL {
        try FileManager.default.createDirectory(
            at: AppPaths.syncBackupsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: AppPaths.syncBackupsDirectory.path
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backupURL = AppPaths.syncBackupsDirectory
            .appending(path: "hosts-before-cloud-restore-\(formatter.string(from: .now)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(InventoryDocument(groups: groups, hosts: hosts))
        try data.write(to: backupURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        return backupURL
    }


    private func sanitizeReferences() {
        let groupIDs = Set(groups.map(\.id))
        for index in groups.indices {
            if groups[index].parentID.map({ !groupIDs.contains($0) || $0 == groups[index].id }) == true {
                groups[index].parentID = nil
            }
        }
        for index in groups.indices {
            var visited: Set<HostGroup.ID> = [groups[index].id]
            var currentID = groups[index].parentID
            while let id = currentID, let current = groups.first(where: { $0.id == id }) {
                guard visited.insert(id).inserted else {
                    groups[index].parentID = nil
                    break
                }
                currentID = current.parentID
            }
        }
        for index in hosts.indices where hosts[index].groupID.map({ !groupIDs.contains($0) }) == true {
            hosts[index].groupID = nil
        }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(InventoryDocument(groups: groups, hosts: hosts))
        try data.write(to: AppPaths.hostsFile, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.hostsFile.path)
    }

    private func sortInventory() {
        var pathsByID: [HostGroup.ID: String] = [:]
        for group in groups where pathsByID[group.id] == nil {
            pathsByID[group.id] = groupPath(for: group.id)
        }
        groups.sort {
            let firstPath = pathsByID[$0.id] ?? $0.name
            let secondPath = pathsByID[$1.id] ?? $1.name
            return firstPath.localizedStandardCompare(secondPath) == .orderedAscending
        }
        hosts.sort {
            let firstGroup = $0.groupID.flatMap { pathsByID[$0] } ?? ""
            let secondGroup = $1.groupID.flatMap { pathsByID[$0] } ?? ""
            let groupOrder = firstGroup.localizedStandardCompare(secondGroup)
            return groupOrder == .orderedSame
                ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                : groupOrder == .orderedAscending
        }
    }

    private func manualKeychainCleanupMessage(for profile: HostProfile, status: OSStatus) -> String {
        "主機已刪除，但舊版 Keychain 項目不允許目前這個 App 簽章移除（\(status)）。密碼不會再被 MyTerm 使用；若要徹底清除，請在「鑰匙圈存取」搜尋服務名稱 tw.local.MySSHClient.host-password，並移除帳號 \(profile.id.uuidString)。"
    }
}
