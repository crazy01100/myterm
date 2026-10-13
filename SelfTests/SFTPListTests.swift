import Foundation

@main struct SFTPListTests {
    static var passed = 0
    static func check(_ ok: Bool, _ name: String) {
        guard ok else { fatalError("FAIL: \(name)") }
        passed += 1
        print("PASS: \(name)")
    }
    static func entry(_ name: String, _ permissions: UInt32 = 0o100644, size: UInt64? = 1, date: Double? = 1) -> SFTPDirectoryEntry {
        SFTPDirectoryEntry(name: name, longName: name, attributes: SFTPFileAttributes(
            size: size, permissions: permissions, modificationTime: date.map(Date.init(timeIntervalSince1970:))))
    }
    static func policyTests() {
        let items = [entry("file10", size: 10, date: 10), entry("file2", size: 2, date: 2),
                     entry("folder10", 0o040755), entry("folder2", 0o040755),
                     entry("missing", size: nil, date: nil), entry("link", 0o120777)]
        for column in SFTPListColumn.allCases {
            for ascending in [true, false] {
                let sort = SFTPListSort(column: column, ascending: ascending)
                let sorted = items.sorted { sort.precedes(SFTPListItem($0), SFTPListItem($1)) }
                check(sorted.prefix(2).allSatisfy(\.isDirectory), "directories first: \(column) \(ascending)")
                check(Set(sorted.map(\.name)) == Set(items.map(\.name)), "no items lost: \(column) \(ascending)")
                if column == .size || column == .modified {
                    check(sorted.last?.name == "missing", "unknown metadata last in both directions")
                    let fileNames = sorted.filter { $0.name.hasPrefix("file") }.map(\.name)
                    check(fileNames == (ascending ? ["file2", "file10"] : ["file10", "file2"]), "raw numeric/time order")
                }
                for lhs in items {
                    check(!sort.precedes(SFTPListItem(lhs), SFTPListItem(lhs)), "strict comparator")
                    for rhs in items where lhs != rhs {
                        check(sort.precedes(SFTPListItem(lhs), SFTPListItem(rhs)) != sort.precedes(SFTPListItem(rhs), SFTPListItem(lhs)), "total order")
                    }
                }
            }
        }
        var sort = SFTPListSort()
        check(items.sorted { sort.precedes(SFTPListItem($0), SFTPListItem($1)) }.prefix(2).map(\.name) == ["folder2", "folder10"], "natural number sorting")
        sort.select(.modified); check(!sort.ascending, "date first newest")
        sort.select(.modified); check(sort.ascending, "same column toggles")
        sort.select(.size); check(!sort.ascending, "size first largest")
        sort.select(.kind); check(sort.ascending, "kind first ascending")
        let same = [entry("file10"), entry("file2")]
        check(same.sorted { sort.precedes(SFTPListItem($0), SFTPListItem($1)) }.map(\.name) == ["file2", "file10"], "kind ties natural name")
        for (name, query, count) in [("Auth-AUTH.txt", "auth", 2), ("文件文件.rb", "文件", 2), ("👩🏽‍💻-👩🏽‍💻", "👩🏽‍💻", 2), ("café.txt", "CAFE\u{301}", 1), ("file.txt", "[", 0), ("file.txt", "", 0)] {
            let ranges = SFTPFilenameSearch.ranges(in: name, query: query)
            check(ranges.count == count, "unicode highlight ranges: \(name)")
            check(SFTPFilenameSearch.matches(name, query: query) == (query.isEmpty || count > 0), "filter and highlight agree")
        }
        check(SFTPFilenameSearch.matches("hello world.txt", query: " world"), "literal spaces preserved")
        check(SFTPFilenameSearch.matches("FILE.TXT", query: ".txt"), "extension partial search")
    }
    @MainActor static func waitForLocal(_ store: LocalFileBrowserStore) async throws {
        for _ in 0..<200 {
            if !store.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("local load timed out")
    }
    @MainActor static func waitForRemote(_ store: SFTPRemoteBrowserStore) async throws {
        for _ in 0..<200 {
            if store.state != .connecting { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("remote load timed out")
    }
    @MainActor static func stores(root: URL, python: String, peer: String) async throws {
        let suite = "MyTerm-SFTPListTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = LocalFileBrowserStore(sortPreferences: defaults)
        try await waitForLocal(local)
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["file2.txt", "file10.txt", "other.rb", ".hidden"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("folder-link"), withDestinationURL: folder)
        local.navigate(to: root); try await waitForLocal(local)
        check(local.visibleEntries.count == 5, "hidden file excluded")
        check(local.visibleEntries.prefix(2).allSatisfy(\.isNavigableDirectory), "confirmed directory link pinned")
        local.selectAllVisible()
        local.searchQuery = "FILE"
        check(local.visibleEntries.map(\.name) == ["file2.txt", "file10.txt"], "local filter case insensitive")
        check(local.selectedEntries.count == 2 && local.selectedURLs.count == 2, "hidden selections pruned")
        local.sorting.select(.size)
        check(local.selectedEntries.count == 2, "sort preserves selection")
        local.reload(); try await waitForLocal(local)
        check(local.searchQuery == "FILE" && local.selectedEntries.count == 2, "local refresh preserves filter and selection")
        local.searchQuery = "no-match"
        check(local.visibleEntries.isEmpty && local.selectedURLs.isEmpty, "empty results clear selection")
        local.searchQuery = ""; local.showHiddenFiles = true; local.selectAllVisible(); local.showHiddenFiles = false
        check(!local.selectedEntries.contains(where: \.isHidden), "hide files removes their selection")
        local.searchQuery = "file"; local.navigate(to: folder); try await waitForLocal(local)
        check(local.searchQuery.isEmpty && local.sorting.column == .size, "navigation clears query preserves sort")
        local.goBack(); try await waitForLocal(local)
        check(local.visibleEntries.count == 5, "back navigation returns unfiltered list")
        local.searchQuery = "file"; local.selectAllVisible()
        let oldLocalURL = local.currentURL, oldLocalSelection = local.selectedURLs
        local.navigate(to: root.appendingPathComponent("missing-directory")); try await waitForLocal(local)
        check(local.errorMessage != nil && local.currentURL == oldLocalURL && local.searchQuery == "file" && local.selectedURLs == oldLocalSelection,
              "failed local bookmark navigation preserves path filter and selection")
        local.goForward(); try await waitForLocal(local)
        check(local.currentURL.path == folder.path, "failed navigation preserves forward history")
        local.goBack(); try await waitForLocal(local)
        check(local.currentURL.path == root.path, "back history survives failed navigation")
        let restored = LocalFileBrowserStore(sortPreferences: defaults)
        check(restored.sorting == local.sorting && restored.searchQuery.isEmpty, "recreated local store restores only sort")
        try await waitForLocal(restored)
        let remote = SFTPRemoteBrowserStore(sortPreferences: defaults)
        check(remote.sorting == SFTPListSort(), "remote independent from local")
        let client = try SFTPClient.connectForTesting(executableURL: URL(fileURLWithPath: python), arguments: [peer, root.path, "normal"], responseTimeout: 2, initializationTimeout: 2)
        client.completeInitialization()
        var host = HostProfile(); host.hostname = "example.invalid"; host.username = "fixture"
        remote.installTestConnection(client, host: host); remote.reload(); try await waitForRemote(remote)
        check(remote.errorMessage == nil && !remote.entries.isEmpty, "actual remote store loads fixture")
        remote.selectAllVisible(); remote.searchQuery = "FILE"
        check(remote.visibleEntries.count == 2 && remote.selectedNames.count == 2, "remote filtering prunes selection")
        remote.sorting.select(.modified)
        check(remote.selectedNames.count == 2, "remote sort keeps selected identities")
        remote.reload(); try await waitForRemote(remote)
        check(remote.searchQuery == "FILE" && remote.visibleEntries.count == 2, "remote refresh retains filter")
        remote.searchQuery = ""; remote.showHiddenFiles = true; remote.selectAllVisible(); remote.showHiddenFiles = false
        check(!remote.selectedEntries.contains(where: \.isHidden), "remote hidden selection pruned")
        remote.searchQuery = "file"; remote.selectAllVisible()
        let oldRemotePath = remote.currentPath, oldRemoteSelection = remote.selectedNames
        remote.navigateToBookmark(path: "/missing-directory", hostID: host.id, hostname: host.hostname, port: host.port, username: host.username)
        try await waitForRemote(remote)
        check(remote.errorMessage != nil && remote.currentPath == oldRemotePath && remote.searchQuery == "file" && remote.selectedNames == oldRemoteSelection,
              "failed remote bookmark preserves old view")
        remote.navigateToBookmark(path: "/folder", hostID: UUID(), hostname: host.hostname, port: host.port, username: host.username)
        check(remote.currentPath == oldRemotePath, "wrong host bookmark cannot navigate")
        remote.searchQuery = "folder"
        remote.open(remote.visibleEntries.first { $0.isDirectory }!); try await waitForRemote(remote)
        check(remote.searchQuery.isEmpty && remote.sorting.column == .modified, "remote navigation clears query keeps sort")
        let remoteRestored = SFTPRemoteBrowserStore(sortPreferences: defaults)
        check(remoteRestored.sorting == remote.sorting && restored.sorting == local.sorting, "both pane preferences survive independently")
        remote.searchQuery = "stale"; remote.disconnect()
        check(remote.searchQuery.isEmpty && remote.visibleEntries.isEmpty, "disconnect clears filter and old entries")
        defaults.set(Data("invalid".utf8), forKey: "sftp.list.sort.local")
        check(SFTPListSort.load(from: defaults, pane: "local") == SFTPListSort(), "invalid preferences fall back")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyTerm-SFTPList-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        policyTests()
        try await stores(root: root, python: CommandLine.arguments[1], peer: CommandLine.arguments[2])
        print("SFTP list tests passed: \(passed)")
    }
}
