import Foundation

enum ConnectionAuditStatus: String, Codable, CaseIterable {
    case connecting
    case connected
    case completed
    case failed
    case cancelled
    case interrupted

    var isOngoing: Bool {
        self == .connecting || self == .connected
    }
}

struct ConnectionAuditRecord: Identifiable, Codable, Equatable {
    static let schemaVersion = 1

    let id: UUID
    let sessionID: UUID
    let hostID: UUID
    let hostName: String
    let hostname: String
    let port: Int
    let username: String
    let connectionProtocol: String
    var sourceDeviceID: UUID?
    var sourceDeviceName: String?
    var platform: HostPlatform?
    let startedAt: Date
    var connectedAt: Date?
    var endedAt: Date?
    var status: ConnectionAuditStatus
    var exitCode: Int32?
    var failureCode: String?
    var failureTitle: String?

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        hostID: UUID,
        hostName: String,
        hostname: String,
        port: Int,
        username: String,
        sourceDeviceID: UUID? = nil,
        sourceDeviceName: String? = nil,
        platform: HostPlatform?,
        startedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.hostID = hostID
        self.hostName = hostName
        self.hostname = hostname
        self.port = port
        self.username = username
        connectionProtocol = "ssh"
        self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceName = sourceDeviceName
        self.platform = platform
        self.startedAt = startedAt
        status = .connecting
    }

    var duration: TimeInterval? {
        guard status != .interrupted else { return nil }
        return (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var retentionReferenceDate: Date {
        status == .interrupted ? startedAt : (endedAt ?? startedAt)
    }
}

struct ConnectionAuditDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var records: [ConnectionAuditRecord]
}

struct ConnectionAuditIndex {
    private(set) var records: [ConnectionAuditRecord]
    let maximumRecordCount: Int

    init(records: [ConnectionAuditRecord] = [], maximumRecordCount: Int = 5_000) {
        self.records = records
        self.maximumRecordCount = max(maximumRecordCount, 1)
        pruneIfNeeded()
    }

    var newestFirst: [ConnectionAuditRecord] {
        records.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    @discardableResult
    mutating func begin(
        sessionID: UUID,
        host: HostProfile,
        username: String,
        at date: Date,
        sourceDeviceID: UUID? = nil,
        sourceDeviceName: String? = nil,
        recordID: UUID = UUID()
    ) -> UUID {
        if let existing = records.first(where: { $0.sessionID == sessionID }) {
            return existing.id
        }
        let record = ConnectionAuditRecord(
            id: recordID,
            sessionID: sessionID,
            hostID: host.id,
            hostName: host.displayName,
            hostname: host.hostname,
            port: host.port,
            username: username,
            sourceDeviceID: sourceDeviceID,
            sourceDeviceName: sourceDeviceName,
            platform: host.detectedPlatform,
            startedAt: date
        )
        records.append(record)
        pruneIfNeeded()
        return record.id
    }

    @discardableResult
    mutating func markConnected(sessionID: UUID, at date: Date) -> Bool {
        guard let index = records.firstIndex(where: { $0.sessionID == sessionID }),
              records[index].status.isOngoing else { return false }
        if records[index].connectedAt == nil {
            records[index].connectedAt = date
        }
        records[index].status = .connected
        return true
    }

    @discardableResult
    mutating func recordDetectedPlatform(
        sessionID: UUID,
        platform: HostPlatform
    ) -> Bool {
        guard let index = records.firstIndex(where: { $0.sessionID == sessionID }),
              records[index].platform == nil else { return false }
        records[index].platform = platform
        return true
    }

    @discardableResult
    mutating func finish(
        sessionID: UUID,
        status: ConnectionAuditStatus,
        at date: Date,
        exitCode: Int32? = nil,
        failureCode: String? = nil,
        failureTitle: String? = nil
    ) -> Bool {
        guard !status.isOngoing,
              let index = records.firstIndex(where: { $0.sessionID == sessionID }),
              records[index].status.isOngoing else { return false }
        records[index].status = status
        records[index].endedAt = status == .interrupted ? nil : date
        records[index].exitCode = exitCode
        records[index].failureCode = failureCode
        records[index].failureTitle = failureTitle
        pruneIfNeeded()
        return true
    }

    @discardableResult
    mutating func recoverInterruptedSessions() -> Bool {
        var changed = false
        for index in records.indices where records[index].status.isOngoing {
            records[index].status = .interrupted
            records[index].endedAt = nil
            changed = true
        }
        return changed
    }

    @discardableResult
    mutating func backfillSourceDevice(id: UUID, name: String) -> Bool {
        var changed = false
        for index in records.indices {
            if records[index].sourceDeviceID == nil {
                records[index].sourceDeviceID = id
                changed = true
            }
            if records[index].sourceDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                records[index].sourceDeviceName = name
                changed = true
            }
        }
        return changed
    }

    @discardableResult
    mutating func mergeFinalized(_ incoming: [ConnectionAuditRecord]) -> Bool {
        let existingIDs = Set(records.map(\.id))
        let additions = incoming.filter { !$0.status.isOngoing && !existingIDs.contains($0.id) }
        guard !additions.isEmpty else { return false }
        records.append(contentsOf: additions)
        pruneIfNeeded()
        return true
    }

    @discardableResult
    mutating func pruneExpired(before cutoff: Date) -> Bool {
        let oldCount = records.count
        records.removeAll {
            !$0.status.isOngoing && $0.retentionReferenceDate < cutoff
        }
        return records.count != oldCount
    }

    func record(sessionID: UUID) -> ConnectionAuditRecord? {
        records.first { $0.sessionID == sessionID }
    }

    private mutating func pruneIfNeeded() {
        while records.count > maximumRecordCount {
            guard let oldestFinalized = records.indices
                .filter({ !records[$0].status.isOngoing })
                .min(by: {
                    let lhs = records[$0]
                    let rhs = records[$1]
                    if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }) else { return }
            records.remove(at: oldestFinalized)
        }
    }
}
