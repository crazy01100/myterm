import Foundation
import CryptoKit

// Content, baseline and pending intent share one atomic local document.
struct SnippetSyncEntry: Codable, Equatable {
    var id: UUID
    var value: CommandSnippet?
    var baseline: CommandSnippet?
    var revision: UInt64 = 0
    var needsReview = false
}
struct SnippetSyncPartition: Codable {
    var enrolled = false
    var entries: [SnippetSyncEntry] = []
}
struct SnippetLibraryState: Codable {
    var schemaVersion = 2
    var lastScope: String?
    var partitions: [String: SnippetSyncPartition] = ["local": .init()]
}
struct SnippetRemoteValue {
    var id: UUID
    var value: CommandSnippet?
    var revision: UInt64
}
enum SnippetSyncError: LocalizedError {
    case invalidData, changed, capacity, conflict, notEnrolled
    var errorDescription: String? {
        switch self {
        case .invalidData: "指令同步資料無法驗證；已保留本機內容。"
        case .changed: "指令或帳號已變更，請重新檢視後再操作。"
        case .capacity: "指令同步已達容量上限；原有內容及待處理變更已保留。"
        case .conflict: "有指令衝突副本待確認，請在指令庫檢視。"
        case .notEnrolled: "常用指令尚未加入此帳號的同步。"
        }
    }
}
enum SnippetSyncPolicy {
    static let maximumEntries = 6_000 // includes retained tombstones
    static let maximumCiphertext = 128 * 1024
    static func scope(project: String, uid: String) -> String {
        let encoded = try! JSONEncoder().encode([project, uid])
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
    static func conflictCopy(_ value: CommandSnippet, baseRevision: UInt64) throws -> CommandSnippet {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = Data("MyTerm.SnippetConflict.v1:\(baseRevision):".utf8)
        data.append(try encoder.encode(value))
        let hex = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        let offsets = [8, 12, 16, 20]
        var text = ""
        for (index, char) in hex.enumerated() { if offsets.contains(index) { text += "-" }; text.append(char) }
        var result = value
        result.id = UUID(uuidString: text)!
        result.title = String(value.title.prefix(72)) + "（衝突副本）"
        return result
    }

    // Pure three-way merge. Conflicting content remains local until explicitly reviewed.
    static func merge(_ partition: SnippetSyncPartition, remote: [SnippetRemoteValue]) throws -> SnippetSyncPartition {
        guard remote.count <= maximumEntries, Set(remote.map(\.id)).count == remote.count else { throw SnippetSyncError.invalidData }
        var result = partition
        let byID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        for entry in partition.entries where entry.revision > 0 {
            guard let cloud = byID[entry.id], cloud.revision >= entry.revision else { throw SnippetSyncError.invalidData }
            if cloud.revision == entry.revision && cloud.value != entry.baseline { throw SnippetSyncError.invalidData }
        }
        for cloud in remote {
            guard cloud.revision > 0, cloud.revision < UInt64(Int64.max), cloud.value?.id == cloud.id || cloud.value == nil else { throw SnippetSyncError.invalidData }
            if let value = cloud.value { _ = try value.validated() }
            guard let index = result.entries.firstIndex(where: { $0.id == cloud.id }) else {
                result.entries.append(.init(id: cloud.id, value: cloud.value, baseline: cloud.value, revision: cloud.revision))
                continue
            }
            var local = result.entries[index]
            // A deterministic conflict copy may already have been approved on another device.
            if local.value == cloud.value {
                local.baseline = cloud.value; local.revision = cloud.revision; local.needsReview = false
            } else if local.revision > 0 && local.baseline == cloud.value {
                local.revision = cloud.revision // only local changed; keep pending intent
            } else if local.revision > 0 && local.value == local.baseline {
                local.value = cloud.value; local.baseline = cloud.value; local.revision = cloud.revision
            } else {
                if let content = local.value ?? cloud.value {
                    let copy = try conflictCopy(content, baseRevision: local.revision)
                    if let existing = result.entries.first(where: { $0.id == copy.id }) {
                        guard existing.value == copy else { throw SnippetSyncError.conflict }
                    } else {
                        result.entries.append(.init(id: copy.id, value: copy, baseline: nil, needsReview: true))
                    }
                }
                // Deletion wins the original UUID; modified content survives as a reviewable copy.
                local.value = local.value == nil || cloud.value == nil ? nil : cloud.value
                local.baseline = cloud.value; local.revision = cloud.revision
            }
            result.entries[index] = local
        }
        try validate(result)
        return result
    }

    static func validate(_ partition: SnippetSyncPartition) throws {
        guard partition.entries.count <= maximumEntries,
              partition.entries.compactMap(\.value).count <= 500,
              Set(partition.entries.map(\.id)).count == partition.entries.count else { throw SnippetSyncError.capacity }
        for entry in partition.entries {
            guard entry.revision < UInt64(Int64.max), entry.revision > 0 || entry.baseline == nil else { throw SnippetSyncError.invalidData }
            for value in [entry.value, entry.baseline].compactMap({ $0 }) {
                guard value.id == entry.id, try value.validated() == value else { throw SnippetSyncError.invalidData }
            }
        }
    }
}
