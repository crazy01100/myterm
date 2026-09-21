import Foundation

/// Allow-listed operational events only. No free-form messages, URLs, identifiers or payloads.
@MainActor
final class SyncDiagnosticsJournal {
    enum Component: String, Codable { case coordinator, metadata, logs, snippets, persistence, lifecycle }
    enum Event: String, Codable {
        case requested, queued, started, completed, incomplete, cancelled, retryScheduled, timedOut
        case accountUnavailable, vaultUnavailable, keyUnavailable, disabled
        case preparing, ready, blocked, downloading, downloaded, merging, uploading, pruning, saving, failed
    }
    struct Entry: Codable {
        let date: Date
        let component: Component
        let event: Event
        let trigger: AutomaticSyncTrigger?
        let roundID: UUID?
        let count: Int?
        let errorCategory: String?
        let errorCode: Int?
    }
    static let shared = SyncDiagnosticsJournal()
    static let maximumBytes = 1_048_576
    private let file: URL
    private let queue = DispatchQueue(label: "tw.local.MyTerm.sync-diagnostics", qos: .utility)
    private var entries: [Entry] = []

    init(file: URL = AppPaths.syncDiagnosticsFile) {
        self.file = file
        if let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: Self.maximumBytes),
               let saved = try? JSONDecoder().decode([Entry].self, from: data) {
                entries = saved.filter { $0.date > Date().addingTimeInterval(-7 * 86400) }.suffix(1500)
            }
        }
    }

    func record(_ component: Component, _ event: Event, trigger: AutomaticSyncTrigger? = nil,
                roundID: UUID? = nil, count: Int? = nil, error: Error? = nil) {
        let ns = error as NSError?
        let category: String?
        switch ns?.domain {
        case NSURLErrorDomain: category = "network"
        case NSCocoaErrorDomain: category = "cocoa"
        case NSPOSIXErrorDomain: category = "posix"
        case nil: category = nil
        default: category = "application"
        }
        entries.append(Entry(date: Date(), component: component, event: event, trigger: trigger,
                             roundID: roundID ?? SyncRoundContext.id, count: count, errorCategory: category, errorCode: ns?.code))
        entries = entries.filter { $0.date > Date().addingTimeInterval(-7 * 86400) }.suffix(1500)
        let snapshot = entries
        let file = file
        let maximumBytes = Self.maximumBytes
        queue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                guard data.count <= maximumBytes else { return }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
                try data.write(to: file, options: [.atomic, .completeFileProtection])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { /* Diagnostics are best-effort; never fail SSH or sync because of telemetry. */ }
        }
    }

    func copyableSummary() -> String {
        // Format from typed entries, never copy raw persisted JSON or localized error descriptions.
        entries.filter { $0.date > Date().addingTimeInterval(-7 * 86400) }.map {
            "\($0.date.ISO8601Format()) \($0.component.rawValue) \($0.event.rawValue) trigger=\($0.trigger?.rawValue ?? "-") round=\($0.roundID?.uuidString ?? "-") count=\($0.count.map(String.init) ?? "-") error=\(Self.safeCategory($0.errorCategory)):\($0.errorCode.map(String.init) ?? "-")"
        }.joined(separator: "\n")
    }

    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private static func safeCategory(_ value: String?) -> String {
        guard let value, ["network", "cocoa", "posix", "application"].contains(value) else { return "-" }
        return value
    }
}
