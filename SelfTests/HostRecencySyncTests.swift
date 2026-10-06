import AppKit
import Foundation

@MainActor
func runHostRecencySyncTests(check: (Bool, String) -> Void) {
    func host(_ name: String) -> HostProfile {
        var value = HostProfile()
        value.name = name
        value.hostname = "192.0.2.10"
        value.username = "test"
        return value
    }
    let a = host("A"), b = host("B"), c = host("C")
    let hosts = [a, b, c]
    let ids = Set(hosts.map(\.id))
    func record(_ host: HostProfile, _ connected: TimeInterval?, ended: TimeInterval = 9_000,
                status: ConnectionAuditStatus = .completed) -> ConnectionAuditRecord {
        var value = ConnectionAuditRecord(sessionID: UUID(), hostID: host.id,
            hostName: host.displayName, hostname: host.hostname, port: host.port,
            username: host.username, platform: nil, startedAt: Date(timeIntervalSince1970: 1))
        value.connectedAt = connected.map { Date(timeIntervalSince1970: $0) }
        value.endedAt = Date(timeIntervalSince1970: ended)
        value.status = status
        return value
    }
    func order(_ value: HostConnectionRecencyIndex) -> [UUID] {
        value.sortingByMostRecentConnection(hosts, canonicalHosts: hosts).map(\.id)
    }
    let logs = [record(a, 100), record(b, 200), record(c, nil, status: .failed)]
    var macA = HostConnectionRecencyIndex(), macB = HostConnectionRecencyIndex()
    macA.recordSuccessfulConnection(for: a.id, at: Date(timeIntervalSince1970: 100))
    macB.recordSuccessfulConnection(for: b.id, at: Date(timeIntervalSince1970: 200))
    check(order(macA) != order(macB), "recency fixture reproduces different device-local ordering")
    macA.mergeSuccessfulConnections(from: logs, validHostIDs: ids)
    macB.mergeSuccessfulConnections(from: logs.reversed(), validHostIDs: ids)
    check(macA == macB && order(macA) == [b.id, a.id, c.id], "synced successful Logs converge both device orders")
    let converged = macA
    macA.mergeSuccessfulConnections(from: logs + logs, validHostIDs: ids)
    check(macA == converged, "duplicate and out-of-order Logs are idempotent")
    macA.mergeSuccessfulConnections(from: [record(a, 50, ended: 99_000)], validHostIDs: ids)
    macA.recordSuccessfulConnection(for: b.id, at: Date(timeIntervalSince1970: 150))
    check(macA == converged, "older Logs and local events never replace newer successful times")
    macA.mergeSuccessfulConnections(from: [record(a, 300, ended: 500), record(b, 200, ended: 90_000)], validHostIDs: ids)
    check(order(macA) == [a.id, b.id, c.id], "authentication time determines order instead of session end time")
    macB.mergeSuccessfulConnections(from: [record(a, 300)], validHostIDs: ids)
    check(macA == macB, "reverse-direction synchronization converges after another connection")
    macA.mergeSuccessfulConnections(from: [record(c, nil, status: .cancelled)], validHostIDs: ids)
    check(macA.lastConnectedAt(for: c.id) == nil, "cancelled unauthenticated attempts never gain recency")
    macA.mergeSuccessfulConnections(from: [record(c, 400, status: .interrupted)], validHostIDs: ids)
    check(order(macA).first == c.id, "successful authentication still counts after an interrupted session")
    macA.mergeSuccessfulConnections(from: [record(b, 500, status: .connected)], validHostIDs: ids)
    check(order(macA).first == b.id, "local ongoing authenticated sessions update recency immediately")
    let retained = macA
    macA.mergeSuccessfulConnections(from: [], validHostIDs: ids)
    check(macA == retained, "retention removal does not erase an already learned connection time")
    let unknown = host("A")
    macA.mergeSuccessfulConnections(from: [record(unknown, 999)], validHostIDs: ids)
    check(macA == retained, "same-name and same-address different UUID is not matched")
    var late = HostConnectionRecencyIndex()
    late.mergeSuccessfulConnections(from: logs, validHostIDs: [])
    check(late.lastConnectedAt(for: b.id) == nil, "Logs arriving before host inventory do not invent hosts")
    late.mergeSuccessfulConnections(from: logs, validHostIDs: ids)
    check(late == converged, "reconciliation after inventory arrival reuses existing Logs")
    late.mergeSuccessfulConnections(from: logs, validHostIDs: Set([a.id, c.id]))
    check(late.lastConnectedAt(for: b.id) == nil, "deleted hosts cannot regain recency from retained Logs")
    late.recordSuccessfulConnection(for: a.id, at: Date(timeIntervalSince1970: .infinity))
    check(late.lastConnectedAt(for: a.id) == Date(timeIntervalSince1970: 100), "non-finite timestamps cannot poison sorting")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyTerm-recency-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("recency.json")
        let store = try HostStore(testHosts: hosts, recencyFileURL: file)
        let inventory = store.hosts
        try store.mergeConnectionRecency(from: logs)
        check(store.hostsByMostRecentConnection(hosts).map(\.id) == [b.id, a.id, c.id], "HostStore publishes the merged order")
        check(store.hosts == inventory, "recency reconciliation leaves host data and updatedAt unchanged")
        check(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600,
              "merged recency remains owner-only on disk")
        let restarted = try HostStore(testHosts: hosts, recencyFileURL: file)
        check(restarted.hostsByMostRecentConnection(hosts).map(\.id) == [b.id, a.id, c.id], "merged recency survives app restart")
        try restarted.mergeConnectionRecency(from: [])
        check(restarted.hostsByMostRecentConnection(hosts).map(\.id) == [b.id, a.id, c.id], "restart after Logs expiry retains learned order")
        let saved = try Data(contentsOf: file)
        try restarted.mergeConnectionRecency(from: logs.reversed())
        check(try Data(contentsOf: file) == saved, "duplicate reconciliation leaves persisted index unchanged")
        var tied = HostConnectionRecencyIndex()
        tied.recordSuccessfulConnection(for: a.id, at: Date(timeIntervalSince1970: 100))
        tied.recordSuccessfulConnection(for: b.id, at: Date(timeIntervalSince1970: 100))
        check(order(tied) == hosts.map(\.id), "equal timestamps retain canonical order")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tied).write(to: file)
        let legacy = try HostStore(testHosts: hosts, recencyFileURL: file)
        try legacy.mergeConnectionRecency(from: logs)
        check(legacy.hostsByMostRecentConnection(hosts).first?.id == b.id, "existing schema-one local indexes accept synchronized history")

        let blockedParent = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedParent)
        let retry = try HostStore(testHosts: hosts, recencyFileURL: blockedParent.appendingPathComponent("recency.json"))
        do {
            try retry.mergeConnectionRecency(from: logs)
            check(false, "failed disk write must throw")
        } catch {
            check(retry.hostsByMostRecentConnection(hosts).map(\.id) == hosts.map(\.id), "failed persistence never publishes an unsaved order")
        }
        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)
        try retry.mergeConnectionRecency(from: logs)
        check(retry.hostsByMostRecentConnection(hosts).first?.id == b.id, "same Logs can retry persistence after a failure")
    } catch {
        check(false, "host recency persistence tests: \(error)")
    }
}
