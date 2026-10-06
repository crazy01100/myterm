import Foundation

@MainActor
func runHostSyncNoticeTests(check: (Bool, String) -> Void) {
    // These integration checks exercise real inventory writes and backups.
    // The standard isolated runner replaces AppPaths only in its copied source.
    guard AppPaths.rootDirectory.path.hasPrefix("/private/tmp/MyTerm-isolated-tests-") else {
        print("SKIP: cloud-merge notice integration requires run-isolated-tests.py")
        return
    }
    let file = AppPaths.hostsFile
    let original = try? Data(contentsOf: file)
    defer {
        try? FileManager.default.removeItem(at: file)
        if let original { try? original.write(to: file) }
    }
    do {
        try AppPaths.prepare()
        var first = HostProfile()
        first.name = "Notice fixture"
        first.hostname = "192.0.2.10"
        first.username = "test"
        var second = first
        second.name = "Updated fixture"
        let store = try HostStore(testHosts: [first],
            recencyFileURL: AppPaths.rootDirectory.appendingPathComponent("notice-test-recency.json"))
        let document = InventoryDocument(groups: [], hosts: [second])
        let backup = try store.applyVerifiedCloudMerge(document, notifyOnSuccess: false)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(InventoryDocument.self, from: Data(contentsOf: file))
        let previous = try decoder.decode(InventoryDocument.self, from: Data(contentsOf: backup))
        check(store.lastNotice == nil && store.hosts.first?.name == second.name,
              "background cloud merge updates inventory without a success alert")
        check(saved.hosts.first?.name == second.name && previous.hosts.first?.name == first.name,
              "silent success retains durable inventory and pre-merge backup")
        store.lastNotice = "Existing cleanup warning"
        _ = try store.applyVerifiedCloudMerge(document, notifyOnSuccess: false)
        check(store.lastNotice == "Existing cleanup warning",
              "silent synchronization preserves an undismissed warning")
        _ = try store.applyVerifiedCloudMerge(document)
        check(store.lastNotice?.contains("已從端對端加密同步套用雲端變更") == true,
              "explicit manual cloud merge retains its completion notice")

        let priorHosts = store.hosts
        store.lastNotice = nil
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do {
            _ = try store.applyVerifiedCloudMerge(InventoryDocument(groups: [], hosts: [first]), notifyOnSuccess: false)
            check(false, "failed cloud inventory write propagates its error")
        } catch {
            check(store.hosts == priorHosts && store.lastNotice == nil,
                  "failed silent merge throws and restores inventory without claiming success")
        }
    } catch {
        check(false, "cloud-merge notice integration: \(error)")
    }
}
