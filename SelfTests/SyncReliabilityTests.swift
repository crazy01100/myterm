import AppKit
import Foundation

@main
struct SyncReliabilityTests {
    @MainActor static func main() async {
        var failures = 0
        var passes = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 } else { passes += 1 }
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw NSError(domain: "SyncTestDeadline", code: 1)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "MyTerm-SyncReliability-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "audit.json")
            let now = Date()
            let store = ConnectionAuditStore(fileURL: file, now: { now }, sourceDeviceID: UUID(), sourceDeviceName: "Synthetic Mac")
            var host = HostProfile()
            host.name = "Synthetic host"
            host.hostname = "192.0.2.1"
            var index = ConnectionAuditIndex()
            let sessionID = UUID()
            index.begin(sessionID: sessionID, host: host, username: "test", at: now,
                        sourceDeviceID: UUID(), sourceDeviceName: "Synthetic remote")
            _ = index.finish(sessionID: sessionID, status: .completed, at: now, exitCode: 0)

            // Fail the real atomic file replacement, without altering any user path or permissions.
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            store.mergeFinalizedFromSync(index.records, referenceDate: now)
            for _ in 0..<100 where store.lastError == nil { try await Task.sleep(for: .milliseconds(10)) }
            check(store.lastError != nil, "atomic persistence failure is surfaced")
            check(store.records.count == 1, "failed persistence preserves the in-memory record")
            try FileManager.default.removeItem(at: file)

            // An identical subsequent download MUST retry the failed write, not only deduplicate memory.
            store.mergeFinalizedFromSync(index.records, referenceDate: now)
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path) || store.lastError != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            check(FileManager.default.fileExists(atPath: file.path), "identical sync retries failed disk persistence")
            check(store.lastError == nil, "successful retry clears the persistence error")
            if FileManager.default.fileExists(atPath: file.path) {
                let saved = try ConnectionAuditStore.loadDocument(from: file)
                check(saved.records.count == 1, "recovered record survives reloading from disk without duplicates")
            }
            try await store.persistForSync()
            check(store.lastError == nil, "sync completion awaits durable storage")

            let suite = "MyTerm-SyncTests-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let journal = SyncDiagnosticsJournal(file: directory.appending(path: "diagnostics/events.json"))
            var scope = "test-scope-a"
            var enabled = true
            var metadataCalls = 0
            var logCalls = 0
            var shouldFailLogs = true
            var shouldWaitMetadata = false
            var prepared = false
            let timing = AutomaticSyncCoordinator.Timing(periodic: 0.08, debounce: 0.01, stale: 60)
            let coordinator = AutomaticSyncCoordinator(defaults: defaults, timing: timing, journal: journal)
            coordinator.configure(context: { .init(scope: scope, enabled: enabled) }, prepare: { prepared = true }, metadata: { _ in
                metadataCalls += 1
                if shouldWaitMetadata { return .waiting("test confirmation") }
                return .completed
            }, logs: { _ in
                logCalls += 1
                return shouldFailLogs ? .retryable("test network") : .completed
            })
            coordinator.request(.launch)
            try await waitUntil { !coordinator.isRunning }
            check(prepared && metadataCalls == 1 && logCalls == 1, "launch prepares context and calls both workers without Settings")
            check(coordinator.lastSuccessfulSyncAt == nil, "metadata-only success never becomes whole-round success")
            shouldFailLogs = false
            coordinator.setActive(true)
            try await waitUntil { coordinator.lastSuccessfulSyncAt != nil }
            check(coordinator.logsOutcome == .completed, "foreground automatically recovers without manual sync")
            let previousCalls = logCalls
            coordinator.request(.logsOpened)
            check(logCalls == previousCalls && !coordinator.isRunning, "fresh Logs page does not launch a redundant round")
            try await waitUntil { logCalls >= previousCalls + 3 }
            coordinator.setActive(false)
            check(metadataCalls == logCalls, "three periodic passes schedule both workers, with no separate Logs throttle")
            try await waitUntil { !coordinator.isRunning }
            let stoppedCalls = logCalls
            try await Task.sleep(for: .milliseconds(120))
            check(logCalls == stoppedCalls, "background pauses periodic polling")

            shouldWaitMetadata = true
            scope = "test-scope-b"
            coordinator.request(.foreground)
            try await waitUntil { !coordinator.isRunning }
            check(coordinator.lastSuccessfulSyncAt == nil && coordinator.logsOutcome == .completed,
                  "metadata confirmation does not block Logs and does not inherit another account's success")
            shouldWaitMetadata = false
            shouldFailLogs = true
            coordinator.setActive(true)
            try await waitUntil { !coordinator.isRunning }
            let failedCalls = logCalls
            shouldFailLogs = false
            for _ in 0..<50 { coordinator.request(.localChange); coordinator.request(.availability) }
            try await Task.sleep(for: .milliseconds(20))
            check(logCalls == failedCalls, "failure waits for the existing periodic tick; local changes do not cause fast retries")
            try await waitUntil { coordinator.lastSuccessfulSyncAt != nil }
            check(coordinator.logsOutcome == .completed, "existing periodic timer recovers a transient failure with no manual action")
            coordinator.setActive(false)
            enabled = false
            coordinator.request(.foreground)
            let disabledCalls = logCalls
            coordinator.request(.manual)
            check(logCalls == disabledCalls && !coordinator.isEnabled, "disabled context prevents worker execution including manual requests")

            // A pending old-account operation must finish/cancel before any new-account operation starts.
            var releaseOld: CheckedContinuation<Void, Never>?
            var starts = 0
            var currentScope = "old"
            let fenced = AutomaticSyncCoordinator(defaults: defaults, timing: timing, journal: journal)
            fenced.configure(context: { .init(scope: currentScope, enabled: true) }, prepare: {}, metadata: { _ in
                starts += 1
                if starts == 1 { await withCheckedContinuation { releaseOld = $0 } }
                return .completed
            }, logs: { _ in .completed })
            fenced.request(.launch)
            try await waitUntil { releaseOld != nil }
            currentScope = "new"
            fenced.request(.foreground)
            check(starts == 1 && fenced.lastSuccessfulSyncAt == nil, "account switch waits for old resources and clears old success")
            releaseOld?.resume()
            try await waitUntil { starts == 2 && !fenced.isRunning }
            check(defaults.object(forKey: "cloudSync.round.lastSuccess.v1.old") == nil,
                  "cancelled old account cannot publish a successful round")
            check(fenced.lastSuccessfulSyncAt != nil, "new context resumes automatically after the old operation releases")

            var gated: CheckedContinuation<Void, Never>?
            var seen: [AutomaticSyncTrigger] = []
            let coalesced = AutomaticSyncCoordinator(defaults: defaults, timing: timing, journal: journal)
            coalesced.configure(context: { .init(scope: "coalescing", enabled: true) }, prepare: {}, metadata: { trigger in
                seen.append(trigger)
                if seen.count == 1 { await withCheckedContinuation { gated = $0 } }
                return .completed
            }, logs: { _ in .completed })
            coalesced.request(.localChange)
            try await waitUntil { gated != nil }
            for _ in 0..<100 { coalesced.request(.localChange) }
            coalesced.request(.confirmedRecentOverwrite)
            coalesced.request(.periodic)
            gated?.resume()
            try await waitUntil { seen.count == 2 && !coalesced.isRunning }
            check(seen == [.localChange, .confirmedRecentOverwrite], "busy requests coalesce while preserving explicit confirmation authority")

            var deadlineTiming = timing
            deadlineTiming.deadline = 0.03
            deadlineTiming.periodic = 0.15
            var attempts = 0
            let deadline = AutomaticSyncCoordinator(defaults: defaults, timing: deadlineTiming, journal: journal)
            deadline.configure(context: { .init(scope: "deadline", enabled: true) }, prepare: {}, metadata: { _ in
                attempts += 1
                if attempts == 1 {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return .cancelled }
                }
                return .completed
            }, logs: { _ in .completed })
            deadline.setActive(true)
            try await waitUntil { attempts == 1 && !deadline.isRunning }
            try await Task.sleep(for: .milliseconds(30))
            check(attempts == 1, "deadline cancellation does not create its own retry timer")
            try await waitUntil { attempts >= 2 && deadline.lastSuccessfulSyncAt != nil }
            deadline.setActive(false)
            check(attempts == 2, "timeout cancels and releases workers before retrying the next round")

            let durableFile = directory.appending(path: "durable.json")
            let durable = ConnectionAuditStore(fileURL: durableFile, sourceDeviceID: UUID(), sourceDeviceName: "Test")
            try FileManager.default.createDirectory(at: durableFile, withIntermediateDirectories: false)
            do { try await durable.persistForSync(); check(false, "durable sync reports write failure") }
            catch { check(true, "durable sync reports write failure") }
            try FileManager.default.removeItem(at: durableFile)
            try await durable.persistForSync()
            check(durable.lastError == nil, "durable sync can recover without a new record")

            let secret = "SECRET_TEST_ACCOUNT_TOKEN_URL"
            journal.record(.logs, .failed, error: NSError(domain: secret, code: 123,
                           userInfo: [NSLocalizedDescriptionKey: secret]))
            let summary = journal.copyableSummary()
            check(!summary.contains(secret) && !summary.contains("test-scope"), "diagnostics redact domains, descriptions and account scope")
            check(summary.contains("periodic") && !summary.contains("retryScheduled") && !summary.contains("trigger=retry "),
                  "diagnostics show periodic recovery without any short retry event")
            await journal.flush()
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "diagnostics/events.json").path)
            check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "diagnostics file is owner-only")
        } catch {
            failures += 1
            print("FAIL: isolated persistence test (\((error as NSError).domain) / \((error as NSError).code))")
        }
        print("\(passes) sync reliability tests passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
