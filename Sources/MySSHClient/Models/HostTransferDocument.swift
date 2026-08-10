import Foundation

enum HostTransferFormat: String, Codable {
    case myTerm = "myterm-host-export-v1"
    case termius = "myterm-termius-host-export-v1"

    var title: String {
        switch self {
        case .myTerm: "MyTerm JSON"
        case .termius: "Termius 主機資料 JSON"
        }
    }
}

enum HostImportDuplicatePolicy: String, CaseIterable, Identifiable {
    case skipExisting
    case keepBoth

    var id: Self { self }

    var title: String {
        switch self {
        case .skipExisting: "跳過相同連線（建議）"
        case .keepBoth: "保留兩筆"
        }
    }

    var explanation: String {
        switch self {
        case .skipExisting: "主機位址、連接埠與預設使用者相同時，不重複匯入。"
        case .keepBoth: "即使連線資料相同也建立新主機，適合需要不同名稱或設定的情況。"
        }
    }
}

struct HostImportGroup: Hashable {
    var sourceID: String
    var name: String
    var parentSourceID: String?
    var createdAt: Date?
}

struct HostImportHost: Hashable {
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var groupSourceID: String?
    var notes: String
    var authenticationMethod: AuthenticationMethod
    var algorithmMode: AlgorithmMode
    var customAlgorithms: CustomAlgorithms
    var detectedPlatform: HostPlatform?
    var referencedPrivateKey: Bool
    var createdAt: Date?
    var updatedAt: Date?
}

struct HostImportPayload {
    var format: HostTransferFormat
    var groups: [HostImportGroup]
    var hosts: [HostImportHost]
    var sourceDescription: String
    var referencedPrivateKeyCount: Int
    var preserveStandaloneGroups = true

    func selectingHostIndices(
        _ indices: Set<Int>,
        preserveStandaloneGroups: Bool = false
    ) -> HostImportPayload {
        let validIndices = indices.filter { hosts.indices.contains($0) }.sorted()
        var result = self
        result.hosts = validIndices.map { hosts[$0] }
        result.referencedPrivateKeyCount = result.hosts.filter(\.referencedPrivateKey).count
        result.preserveStandaloneGroups = preserveStandaloneGroups

        guard !preserveStandaloneGroups else { return result }
        var groupsByID: [String: HostImportGroup] = [:]
        for group in groups where groupsByID[group.sourceID] == nil {
            groupsByID[group.sourceID] = group
        }
        var requiredGroupIDs: Set<String> = []
        for host in result.hosts {
            var currentID = host.groupSourceID
            var visited: Set<String> = []
            while let id = currentID, visited.insert(id).inserted {
                requiredGroupIDs.insert(id)
                currentID = groupsByID[id]?.parentSourceID
            }
        }
        result.groups = groups.filter { requiredGroupIDs.contains($0.sourceID) }
        return result
    }

    func groupPath(forHostAt index: Int) -> String {
        guard hosts.indices.contains(index), let sourceID = hosts[index].groupSourceID else {
            return "未分類"
        }
        var groupsByID: [String: HostImportGroup] = [:]
        for group in groups where groupsByID[group.sourceID] == nil {
            groupsByID[group.sourceID] = group
        }
        var names: [String] = []
        var currentID: String? = sourceID
        var visited: Set<String> = []
        while let id = currentID, visited.insert(id).inserted, let group = groupsByID[id] {
            names.append(group.name)
            currentID = group.parentSourceID
        }
        return names.isEmpty ? "未分類" : names.reversed().joined(separator: " / ")
    }
}

struct HostImportMergeResult {
    var document: InventoryDocument
    var sourceHostCount: Int
    var importedHostCount: Int
    var skippedDuplicateCount: Int
    var invalidHostCount: Int
    var existingConflictCount: Int
    var sourceDuplicateCount: Int
    var addedGroupCount: Int
    var issues: [String]
}

struct HostImportApplicationResult {
    var merge: HostImportMergeResult
    var backupURL: URL
}

enum HostTransferError: LocalizedError {
    case fileTooLarge
    case unsupportedFormat
    case malformedFile
    case tooManyRecords
    case duplicateGroupIdentifier
    case invalidGroupHierarchy
    case noImportableHosts

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: "檔案超過 10 MB，為避免意外耗用資源而停止匯入。"
        case .unsupportedFormat: "不支援這個檔案格式。請選擇 MyTerm JSON 或 MyTerm 產生的 Termius 主機資料 JSON。"
        case .malformedFile: "檔案內容不完整或格式不正確。"
        case .tooManyRecords: "檔案包含過多主機或群組，無法安全匯入。"
        case .duplicateGroupIdentifier: "匯入檔含有重複的群組識別碼。"
        case .invalidGroupHierarchy: "匯入檔的群組階層遺失上層群組或形成循環。"
        case .noImportableHosts: "沒有可匯入的有效主機。"
        }
    }
}

private struct TransferFormatProbe: Decodable {
    var format: String
}

private struct MyTermTransferDocument: Codable {
    var format: String
    var exportedAt: String
    var source: String
    var security: TransferSecurityRecord
    var groups: [MyTermTransferGroup]
    var hosts: [MyTermTransferHost]
}

private struct TransferSecurityRecord: Codable {
    var containsPasswords: Bool
    var containsPrivateKeys: Bool
    var containsPrivateKeyPaths: Bool?
    var note: String
}

private struct MyTermTransferGroup: Codable {
    var sourceID: String
    var name: String
    var parentSourceID: String?
    var createdAt: String?
}

private struct MyTermTransferHost: Codable {
    var sourceID: String
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var groupSourceID: String?
    var notes: String
    var authenticationMethod: String
    var algorithmMode: String
    var customAlgorithms: CustomAlgorithms
    var detectedPlatform: String?
    var createdAt: String?
    var updatedAt: String?
}

private struct TermiusTransferDocument: Decodable {
    var format: String
    var source: String?
    var groups: [TermiusTransferGroup]
    var hosts: [TermiusTransferHost]
}

private struct TermiusTransferGroup: Decodable {
    var sourceID: Int
    var name: String
    var parentSourceID: Int?
    var updatedAt: String?
}

private struct TermiusTransferHost: Decodable {
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var group: String
    var detectedPlatform: String?
    var hasTermiusPrivateKey: Bool
    var updatedAt: String?
}

enum HostTransferService {
    static let maximumFileSize = 10 * 1_024 * 1_024
    static let maximumRecordCount = 10_000

    static func decodeImport(data: Data) throws -> HostImportPayload {
        guard data.count <= maximumFileSize else { throw HostTransferError.fileTooLarge }
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(TransferFormatProbe.self, from: data) else {
            throw HostTransferError.malformedFile
        }

        switch HostTransferFormat(rawValue: probe.format) {
        case .myTerm:
            guard let document = try? decoder.decode(MyTermTransferDocument.self, from: data) else {
                throw HostTransferError.malformedFile
            }
            try validateRecordCounts(groups: document.groups.count, hosts: document.hosts.count)
            return HostImportPayload(
                format: .myTerm,
                groups: document.groups.map {
                    HostImportGroup(
                        sourceID: $0.sourceID,
                        name: $0.name,
                        parentSourceID: $0.parentSourceID,
                        createdAt: parseDate($0.createdAt)
                    )
                },
                hosts: document.hosts.map {
                    let sourceAuthentication = AuthenticationMethod(rawValue: $0.authenticationMethod) ?? .password
                    return HostImportHost(
                        name: $0.name,
                        hostname: $0.hostname,
                        port: $0.port,
                        username: $0.username,
                        groupSourceID: $0.groupSourceID,
                        notes: $0.notes,
                        authenticationMethod: sourceAuthentication == .password ? .password : .sshAgent,
                        algorithmMode: AlgorithmMode(rawValue: $0.algorithmMode) ?? .systemDefault,
                        customAlgorithms: $0.customAlgorithms,
                        detectedPlatform: $0.detectedPlatform.flatMap(HostPlatform.init(rawValue:)),
                        referencedPrivateKey: sourceAuthentication == .privateKey,
                        createdAt: parseDate($0.createdAt),
                        updatedAt: parseDate($0.updatedAt)
                    )
                },
                sourceDescription: document.source,
                referencedPrivateKeyCount: document.hosts.filter { $0.authenticationMethod == AuthenticationMethod.privateKey.rawValue }.count
            )

        case .termius:
            guard let document = try? decoder.decode(TermiusTransferDocument.self, from: data) else {
                throw HostTransferError.malformedFile
            }
            try validateRecordCounts(groups: document.groups.count, hosts: document.hosts.count)
            let groups = document.groups.map {
                HostImportGroup(
                    sourceID: String($0.sourceID),
                    name: $0.name,
                    parentSourceID: $0.parentSourceID.map(String.init),
                    createdAt: parseDate($0.updatedAt)
                )
            }
            let pathMap = try importedGroupPaths(groups: groups)
            var IDsByPath: [String: String] = [:]
            for (sourceID, path) in pathMap where IDsByPath[pathKey(path)] == nil {
                IDsByPath[pathKey(path)] = sourceID
            }
            return HostImportPayload(
                format: .termius,
                groups: groups,
                hosts: document.hosts.map { host in
                    let groupPath = host.group.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    let groupSourceID = groupPath.isEmpty
                        ? nil
                        : IDsByPath[pathKey(groupPath)] ?? "__missing_group_path__:\(groupPath)"
                    return HostImportHost(
                        name: host.name,
                        hostname: host.hostname,
                        port: host.port,
                        username: host.username,
                        groupSourceID: groupSourceID,
                        notes: "",
                        authenticationMethod: host.hasTermiusPrivateKey ? .sshAgent : .password,
                        algorithmMode: .systemDefault,
                        customAlgorithms: CustomAlgorithms(),
                        detectedPlatform: host.detectedPlatform.flatMap(HostPlatform.init(rawValue:)),
                        referencedPrivateKey: host.hasTermiusPrivateKey,
                        createdAt: parseDate(host.updatedAt),
                        updatedAt: parseDate(host.updatedAt)
                    )
                },
                sourceDescription: document.source ?? "Termius",
                referencedPrivateKeyCount: document.hosts.filter(\.hasTermiusPrivateKey).count
            )

        case nil:
            throw HostTransferError.unsupportedFormat
        }
    }

    static func exportData(groups: [HostGroup], hosts: [HostProfile]) throws -> Data {
        let document = MyTermTransferDocument(
            format: HostTransferFormat.myTerm.rawValue,
            exportedAt: formatDate(.now),
            source: "MyTerm",
            security: TransferSecurityRecord(
                containsPasswords: false,
                containsPrivateKeys: false,
                containsPrivateKeyPaths: false,
                note: "Host metadata only. Passwords, passphrases, private keys, tokens, and local private-key paths are excluded."
            ),
            groups: groups.map {
                MyTermTransferGroup(
                    sourceID: $0.id.uuidString,
                    name: $0.name,
                    parentSourceID: $0.parentID?.uuidString,
                    createdAt: formatDate($0.createdAt)
                )
            },
            hosts: hosts.map {
                MyTermTransferHost(
                    sourceID: $0.id.uuidString,
                    name: $0.name,
                    hostname: $0.hostname,
                    port: $0.port,
                    username: $0.username,
                    groupSourceID: $0.groupID?.uuidString,
                    notes: $0.notes,
                    authenticationMethod: $0.authenticationMethod.rawValue,
                    algorithmMode: $0.algorithmMode.rawValue,
                    customAlgorithms: $0.customAlgorithms,
                    detectedPlatform: $0.detectedPlatform?.rawValue,
                    createdAt: formatDate($0.createdAt),
                    updatedAt: formatDate($0.updatedAt)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    static func merge(
        existing: InventoryDocument,
        payload: HostImportPayload,
        duplicatePolicy: HostImportDuplicatePolicy
    ) throws -> HostImportMergeResult {
        let importedGroupsByID = try validatedImportedGroups(payload.groups)
        let orderedGroupIDs = try topologicallySortedGroupIDs(importedGroupsByID)
        var mergedGroups = existing.groups
        var mergedHosts = existing.hosts
        var targetGroupIDs: [String: HostGroup.ID] = [:]
        var pathsByTargetID = existingGroupPaths(existing.groups)
        var targetIDsByPath: [String: HostGroup.ID] = [:]
        for (groupID, path) in pathsByTargetID where targetIDsByPath[pathKey(path)] == nil {
            targetIDsByPath[pathKey(path)] = groupID
        }
        var addedGroupCount = 0

        for sourceID in orderedGroupIDs {
            guard let imported = importedGroupsByID[sourceID] else { continue }
            let parentTargetID = imported.parentSourceID.flatMap { targetGroupIDs[$0] }
            let parentPath = parentTargetID.flatMap { pathsByTargetID[$0] } ?? ""
            let name = imported.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let fullPath = parentPath.isEmpty ? name : "\(parentPath) / \(name)"
            if let existingID = targetIDsByPath[pathKey(fullPath)] {
                targetGroupIDs[sourceID] = existingID
                continue
            }
            let group = HostGroup(name: name, parentID: parentTargetID, createdAt: imported.createdAt ?? .now)
            mergedGroups.append(group)
            targetGroupIDs[sourceID] = group.id
            pathsByTargetID[group.id] = fullPath
            targetIDsByPath[pathKey(fullPath)] = group.id
            addedGroupCount += 1
        }

        let existingKeys = Set(existing.hosts.map(connectionKey))
        var acceptedKeys = existingKeys
        var sourceKeys: Set<String> = []
        var skippedDuplicateCount = 0
        var existingConflictCount = 0
        var sourceDuplicateCount = 0
        var invalidHostCount = 0
        var issues: [String] = []
        var importedHostCount = 0

        for imported in payload.hosts {
            if let sourceGroupID = imported.groupSourceID, targetGroupIDs[sourceGroupID] == nil {
                invalidHostCount += 1
                if issues.count < 8 {
                    let label = imported.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? imported.hostname
                        : imported.name
                    issues.append("\(label)：找不到匯入檔指定的群組。")
                }
                continue
            }
            var profile = HostProfile()
            profile.name = imported.name
            profile.hostname = imported.hostname
            profile.port = imported.port
            profile.username = imported.username
            profile.groupID = imported.groupSourceID.flatMap { targetGroupIDs[$0] }
            profile.notes = imported.notes
            profile.authenticationMethod = imported.authenticationMethod == .password ? .password : .sshAgent
            profile.privateKeyPath = ""
            profile.algorithmMode = imported.algorithmMode
            profile.customAlgorithms = imported.customAlgorithms
            profile.detectedPlatform = imported.detectedPlatform
            profile.createdAt = imported.createdAt ?? .now
            profile.updatedAt = imported.updatedAt ?? profile.createdAt

            do {
                var validated = try profile.validated()
                validated.createdAt = profile.createdAt
                validated.updatedAt = profile.updatedAt
                let key = connectionKey(validated)
                if existingKeys.contains(key) { existingConflictCount += 1 }
                if !sourceKeys.insert(key).inserted { sourceDuplicateCount += 1 }
                if duplicatePolicy == .skipExisting && acceptedKeys.contains(key) {
                    skippedDuplicateCount += 1
                    continue
                }
                acceptedKeys.insert(key)
                mergedHosts.append(validated)
                importedHostCount += 1
            } catch {
                invalidHostCount += 1
                if issues.count < 8 {
                    let label = imported.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? imported.hostname
                        : imported.name
                    issues.append("\(label)：\(error.localizedDescription)")
                }
            }
        }

        if !payload.preserveStandaloneGroups {
            let existingGroupIDs = Set(existing.groups.map(\.id))
            var groupsByID: [HostGroup.ID: HostGroup] = [:]
            for group in mergedGroups where groupsByID[group.id] == nil { groupsByID[group.id] = group }
            var requiredGroupIDs = Set(mergedHosts.compactMap(\.groupID))
            var pending = Array(requiredGroupIDs)
            while let id = pending.popLast(), let parentID = groupsByID[id]?.parentID,
                  requiredGroupIDs.insert(parentID).inserted {
                pending.append(parentID)
            }
            mergedGroups.removeAll {
                !existingGroupIDs.contains($0.id) && !requiredGroupIDs.contains($0.id)
            }
            addedGroupCount = mergedGroups.filter { !existingGroupIDs.contains($0.id) }.count
        }

        return HostImportMergeResult(
            document: InventoryDocument(groups: mergedGroups, hosts: mergedHosts),
            sourceHostCount: payload.hosts.count,
            importedHostCount: importedHostCount,
            skippedDuplicateCount: skippedDuplicateCount,
            invalidHostCount: invalidHostCount,
            existingConflictCount: existingConflictCount,
            sourceDuplicateCount: sourceDuplicateCount,
            addedGroupCount: addedGroupCount,
            issues: issues
        )
    }

    private static func validateRecordCounts(groups: Int, hosts: Int) throws {
        guard groups <= maximumRecordCount, hosts <= maximumRecordCount else {
            throw HostTransferError.tooManyRecords
        }
    }

    private static func validatedImportedGroups(_ groups: [HostImportGroup]) throws -> [String: HostImportGroup] {
        var result: [String: HostImportGroup] = [:]
        for var group in groups {
            group.name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !group.sourceID.isEmpty, !group.name.isEmpty, group.name != "未分類" else {
                throw HostTransferError.invalidGroupHierarchy
            }
            guard result[group.sourceID] == nil else { throw HostTransferError.duplicateGroupIdentifier }
            result[group.sourceID] = group
        }
        for group in result.values where group.parentSourceID.map({ result[$0] == nil }) == true {
            throw HostTransferError.invalidGroupHierarchy
        }
        return result
    }

    private static func topologicallySortedGroupIDs(_ groups: [String: HostImportGroup]) throws -> [String] {
        enum VisitState { case visiting, visited }
        var states: [String: VisitState] = [:]
        var result: [String] = []
        func visit(_ id: String) throws {
            if states[id] == .visiting { throw HostTransferError.invalidGroupHierarchy }
            if states[id] == .visited { return }
            states[id] = .visiting
            if let parentID = groups[id]?.parentSourceID { try visit(parentID) }
            states[id] = .visited
            result.append(id)
        }
        for id in groups.keys.sorted() { try visit(id) }
        return result
    }

    private static func importedGroupPaths(groups: [HostImportGroup]) throws -> [String: String] {
        let byID = try validatedImportedGroups(groups)
        let orderedIDs = try topologicallySortedGroupIDs(byID)
        var result: [String: String] = [:]
        for id in orderedIDs {
            guard let group = byID[id] else { continue }
            let parentPath = group.parentSourceID.flatMap { result[$0] } ?? ""
            result[id] = parentPath.isEmpty ? group.name : "\(parentPath) / \(group.name)"
        }
        return result
    }

    private static func existingGroupPaths(_ groups: [HostGroup]) -> [HostGroup.ID: String] {
        var byID: [HostGroup.ID: HostGroup] = [:]
        for group in groups where byID[group.id] == nil { byID[group.id] = group }
        var result: [HostGroup.ID: String] = [:]
        func path(for id: HostGroup.ID, visited: Set<HostGroup.ID> = []) -> String {
            if let known = result[id] { return known }
            guard let group = byID[id], !visited.contains(id) else { return "" }
            let parentPath = group.parentID.map { path(for: $0, visited: visited.union([id])) } ?? ""
            let value = parentPath.isEmpty ? group.name : "\(parentPath) / \(group.name)"
            result[id] = value
            return value
        }
        for id in byID.keys { _ = path(for: id) }
        return result
    }

    private static func connectionKey(_ host: HostProfile) -> String {
        "\(pathKey(host.hostname))|\(host.port)|\(host.username)"
    }

    private static func pathKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        if let date = internet.date(from: value) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone(secondsFromGMT: 0)
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: value)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
