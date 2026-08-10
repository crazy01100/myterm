import CryptoKit
import Foundation

enum MetadataSyncBaselineError: LocalizedError, Equatable {
    case invalidFile
    case previewNotEligible
    case previewOutdated

    var errorDescription: String? {
        switch self {
        case .invalidFile: "這台 Mac 的同步基線格式不正確。"
        case .previewNotEligible: "只有本機與雲端全部相同時，才能建立同步基線。"
        case .previewOutdated: "主機資料已在預覽後改變，請重新整理後再建立同步基線。"
        }
    }
}

struct MetadataSyncBaselineEntry: Codable, Equatable, Sendable {
    let recordID: UUID
    let recordType: SyncRecordType
    let remoteRevision: UInt64
    let localContentDigest: String
    let remoteRecordDigest: String
}

struct MetadataSyncBaseline: Codable, Equatable, Sendable {
    let schemaVersion: UInt32
    let ownerUIDDigest: String
    let createdAt: Date
    let deviceID: UUID
    let entries: [MetadataSyncBaselineEntry]
}

struct MetadataSyncBaselineSummary: Equatable, Sendable {
    let recordCount: Int
    let createdAt: Date
    let minimumRevision: UInt64
    let maximumRevision: UInt64
}

struct MetadataSyncBaselineStore: Sendable {
    static let schemaVersion: UInt32 = 1
    let directoryURL: URL

    init(directoryURL: URL = AppPaths.syncDirectory) {
        self.directoryURL = directoryURL
    }

    func load(ownerUID: String) throws -> MetadataSyncBaseline? {
        let digest = Self.ownerDigest(ownerUID)
        let fileURL = directoryURL.appending(path: "metadata-baseline-\(digest).json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 4 * 1024 * 1024,
              let baseline = try? JSONDecoder.baseline.decode(MetadataSyncBaseline.self, from: data),
              baseline.schemaVersion == Self.schemaVersion,
              baseline.ownerUIDDigest == digest,
              baseline.entries.count <= MetadataSyncPreviewPlanner.maximumRecordCount,
              Set(baseline.entries.map(\.recordID)).count == baseline.entries.count,
              baseline.entries.allSatisfy({
                  ($0.recordType == .group || $0.recordType == .host)
                      && $0.remoteRevision >= 1
                      && $0.localContentDigest.count == 64
                      && $0.remoteRecordDigest.count == 64
              }) else {
            throw MetadataSyncBaselineError.invalidFile
        }
        return baseline
    }

    @discardableResult
    func save(_ baseline: MetadataSyncBaseline, ownerUID: String) throws -> URL {
        let digest = Self.ownerDigest(ownerUID)
        guard baseline.schemaVersion == Self.schemaVersion,
              baseline.ownerUIDDigest == digest else {
            throw MetadataSyncBaselineError.invalidFile
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let fileURL = directoryURL.appending(path: "metadata-baseline-\(digest).json")
        try JSONEncoder.baseline.encode(baseline).write(
            to: fileURL,
            options: [.atomic, .completeFileProtection]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return fileURL
    }

    static func ownerDigest(_ ownerUID: String) -> String {
        SHA256.hash(data: Data(ownerUID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum MetadataSyncBaselinePlanner {
    static func makeBaseline(
        localGroups: [HostGroup],
        localHosts: [HostProfile],
        remoteRecords: [EncryptedSyncRecord],
        ownerUID: String,
        masterKey: VaultMasterKey,
        deviceID: UUID,
        createdAt: Date = .now
    ) throws -> MetadataSyncBaseline {
        let preview = try MetadataSyncPreviewPlanner.makePreview(
            localGroups: localGroups,
            localHosts: localHosts,
            remoteRecords: remoteRecords,
            ownerUID: ownerUID,
            masterKey: masterKey,
            generatedAt: createdAt
        )
        let expectedCount = localGroups.count + localHosts.count
        guard expectedCount > 0,
              remoteRecords.count == expectedCount,
              preview.unchangedCount == expectedCount,
              preview.uploadCount == 0,
              preview.downloadCount == 0,
              preview.conflictCount == 0,
              preview.remoteTombstoneCount == 0 else {
            throw MetadataSyncBaselineError.previewNotEligible
        }

        var localDigests: [UUID: (SyncRecordType, String)] = [:]
        for group in localGroups {
            localDigests[group.id] = (.group, try MetadataSyncCodec.contentDigest(group: group))
        }
        for host in localHosts {
            localDigests[host.id] = (.host, try MetadataSyncCodec.contentDigest(host: host))
        }
        let entries = try remoteRecords.map { record -> MetadataSyncBaselineEntry in
            guard let local = localDigests[record.id], local.0 == record.recordType else {
                throw MetadataSyncBaselineError.previewNotEligible
            }
            return MetadataSyncBaselineEntry(
                recordID: record.id,
                recordType: record.recordType,
                remoteRevision: record.revision,
                localContentDigest: local.1,
                remoteRecordDigest: try MetadataSyncCodec.encryptedRecordDigest(record)
            )
        }.sorted { $0.recordID.uuidString < $1.recordID.uuidString }

        return MetadataSyncBaseline(
            schemaVersion: MetadataSyncBaselineStore.schemaVersion,
            ownerUIDDigest: MetadataSyncBaselineStore.ownerDigest(ownerUID),
            createdAt: createdAt,
            deviceID: deviceID,
            entries: entries
        )
    }

    static func summary(_ baseline: MetadataSyncBaseline) -> MetadataSyncBaselineSummary {
        let revisions = baseline.entries.map(\.remoteRevision)
        return MetadataSyncBaselineSummary(
            recordCount: baseline.entries.count,
            createdAt: baseline.createdAt,
            minimumRevision: revisions.min() ?? 0,
            maximumRevision: revisions.max() ?? 0
        )
    }

    static func replacingEntry(
        _ entry: MetadataSyncBaselineEntry,
        in baseline: MetadataSyncBaseline
    ) -> MetadataSyncBaseline {
        var entries = baseline.entries.filter { $0.recordID != entry.recordID }
        entries.append(entry)
        entries.sort { $0.recordID.uuidString < $1.recordID.uuidString }
        return MetadataSyncBaseline(
            schemaVersion: baseline.schemaVersion,
            ownerUIDDigest: baseline.ownerUIDDigest,
            createdAt: baseline.createdAt,
            deviceID: baseline.deviceID,
            entries: entries
        )
    }
}

private extension JSONEncoder {
    static var baseline: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var baseline: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
