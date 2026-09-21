import AppKit
import Foundation

@main
struct QuickActionTests {
    static func main() throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            passed += 1; print("PASS: \(message)")
        }
        let hostID = UUID(), otherID = UUID()
        let target = QuickSSHRequest.parse("ops@192.0.2.10")!
        check(target.port == 22 && target.username == "ops", "temporary connection defaults to port 22")
        check(QuickSSHRequest.parse(" ops@Server.Example.COM:2222 ")?.displayAddress == "ops@server.example.com:2222", "DNS and explicit port normalize without DNS lookup")
        check(QuickSSHRequest.parse("ops@[2001:0DB8::10]:2222")?.displayAddress == "ops@[2001:db8::10]:2222", "bracketed IPv6 normalizes")
        check(QuickSSHRequest.parse("ops@[::ffff:192.0.2.10]")?.hostname == "[::ffff:c000:20a]", "IPv4-mapped IPv6 uses valid HostProfile representation")
        check(QuickSSHRequest.parse("Ops@192.0.2.10") != target, "account matching is case sensitive")
        let invalid = ["ops@", "@192.0.2.10", "ops@@192.0.2.10", "ops@999.0.2.10", "ops@127.1", "ops@192.0.2.10:", "ops@192.0.2.10:0", "ops@192.0.2.10:65536", "ops@192.0.2.10:-1", "ops@192.0.2.10:+22", "ops@192.0.2.10:abc", "ops@[2001:db8:::1]", "ops@2001:db8::1", "ops@[::1]junk", "ops@host..example", "ops@-host", "ops@host-", "ops@host/path", "ops@host;id", "ops@host$(id)", "ops@host\n", "ops@host\t", "ssh ops@host", "ssh://ops@host", "ops:password@host", "-oProxyCommand=bad@host", "ops@host -oProxyCommand=bad", "ops@" + String(repeating: "a", count: 64) + ".example"]
        for input in invalid { check(QuickSSHRequest.parse(input) == nil, "malformed endpoint rejected: \(input.debugDescription)") }
        var ephemeral = try target.temporaryProfile()
        check(ephemeral.authenticationMethod == .sshAgent && ephemeral.algorithmMode == .systemDefault && ephemeral.privateKeyPath.isEmpty, "temporary profile uses system authentication and no stored key override")
        ephemeral.authenticationMethod = .password
        check(!SSHSessionOrigin.temporary.permitsPasswordBinding(host: ephemeral, username: "ops"), "temporary origin refuses password binding even with password authentication")
        check(SSHSessionOrigin.savedHost.permitsPasswordBinding(host: ephemeral, username: "ops"), "saved profile password binding remains available")
        check(!SSHSessionOrigin.savedHost.permitsPasswordBinding(host: ephemeral, username: "another"), "different account cannot use saved profile password")
        let existing = QuickActionItem(id: .session(UUID()), section: .sessions, title: "Existing", detail: "", hint: "切換", symbol: "terminal", keywords: "", endpoint: target)
        let wrong = QuickActionItem(id: .host(UUID()), section: .hosts, title: "ops@192.0.2.10", detail: "", hint: "連線", symbol: "", keywords: "", endpoint: QuickSSHRequest.parse("other@192.0.2.10"))
        let endpointResults = QuickActionSearch.results([wrong, existing], query: "ops@192.0.2.10:22")
        check(endpointResults.map(\.id) == [existing.id, .temporarySSH(target)], "exact endpoint precedes temporary action without inheriting similarly named host")
        check(QuickActionSearch.results([], query: "ops@192.0.2.10:bad").isEmpty, "invalid input cannot create a temporary action")
        let session = QuickActionItem(id: .session(UUID()), section: .sessions, title: "Web (1)", detail: "ops@192.0.2.10 · 已中斷", hint: "切換", symbol: "terminal", keywords: "正式 / 網頁", hostID: hostID)
        let duplicate = QuickActionItem(id: .host(hostID), section: .hosts, title: "Web", detail: "192.0.2.10", hint: "連線", symbol: "server.rack", keywords: "", hostID: hostID)
        let other = QuickActionItem(id: .host(otherID), section: .hosts, title: "Web", detail: "admin@192.0.2.11", hint: "連線", symbol: "server.rack", keywords: "測試 / 網頁", hostID: otherID)
        let inventory = [session, duplicate, other] + QuickActionItem.operations
        check(QuickActionSearch.results(inventory, query: "  WEB  ").map(\.id) == [session.id, other.id], "case/whitespace and open host deduplication retain distinct IDs")
        check(QuickActionSearch.results(inventory, query: "ops 正式 192.0.2.10").map(\.id) == [session.id], "multi-token matching spans account, endpoint and group")
        check(QuickActionSearch.results(inventory, query: "測試 網頁").map(\.id) == [other.id], "nested group keywords locate unopened host")
        check(QuickActionSearch.results(inventory, query: "missing").isEmpty, "no results do not invent a destination")
        check(QuickActionSearch.results(inventory, query: "下載").map(\.id) == [.operation(.sftp)], "operation aliases find SFTP")
        check(QuickActionSearch.results(inventory, query: "\n\t").count == 9, "empty query retains sections without duplicate hosts")
        check(QuickActionSearch.results([duplicate, other], query: "web").count == 2, "closing session restores host result")
        check(QuickActionSearch.results([other], query: "192.0.2.10").isEmpty, "removed host is not replaced by same-name host")
        let prefix = QuickActionItem(id: .host(UUID()), section: .hosts, title: "Web staging", detail: "", hint: "", symbol: "", keywords: "")
        check(QuickActionSearch.results([prefix, other], query: "web").first?.id == other.id, "exact title precedes prefix")
        check(QuickActionSearch.results(inventory, query: "指令庫").map(\.id) == [.operation(.snippets)], "snippet library is discoverable without executing a command")
        let suite = "MyTerm.QuickActions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let commandK = AppShortcutDefinition.command(keyCode: 40, key: "K")
        let fresh = AppShortcutStore(defaults: defaults)
        check(fresh.shortcut(for: .openQuickActions) == commandK, "fresh install binds Command-K")
        try fresh.assign(nil, to: .openQuickActions)
        check(AppShortcutStore(defaults: defaults).shortcut(for: .openQuickActions) == nil, "disabled assignment survives relaunch")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        check(!fresh.isManagedDefault(event), "disabled Command-K is not swallowed")
        try fresh.reset(.openQuickActions)
        check(fresh.action(matching: event) == .openQuickActions, "single reset restores binding")
        try fresh.assign(.commandOption(keyCode: 40, key: "K"), to: .openQuickActions)
        check(fresh.action(matching: event) == nil, "custom shortcut releases old binding")
        for shortcut in [AppShortcutDefinition.command(keyCode: 3, key: "F"), .command(keyCode: 69, key: "+")] {
            do { try fresh.assign(shortcut, to: .openQuickActions); check(false, "must reject conflict") }
            catch AppShortcutAssignmentError.conflict { check(true, "action or alias conflict rejected") }
        }
        for shortcut in [AppShortcutDefinition.command(keyCode: 12, key: "Q"), .commandShift(keyCode: 34, key: "I"), .commandShift(keyCode: 14, key: "E")] {
            do { try fresh.assign(shortcut, to: .openQuickActions); check(false, "must reject reserved") }
            catch AppShortcutAssignmentError.reserved { check(true, "macOS or fixed menu binding protected") }
        }
        let legacy: [AppShortcutAction: AppShortcutDefinition] = [.openHosts: commandK]
        defaults.set(try JSONEncoder().encode(legacy), forKey: AppShortcutStore.storageKey)
        defaults.removeObject(forKey: AppShortcutStore.quickActionsMigrationKey)
        let migrated = AppShortcutStore(defaults: defaults)
        check(migrated.shortcut(for: .openQuickActions) == nil && migrated.action(matching: event) == .openHosts, "migration preserves existing Command-K assignment")
        check(migrated.shortcut(for: .copyTerminal) == nil, "unrelated disabled actions remain disabled")
        try migrated.assign(nil, to: .openHosts)
        check(AppShortcutStore(defaults: defaults).shortcut(for: .openQuickActions) == nil, "freeing conflict does not repeat migration")
        defaults.removeObject(forKey: AppShortcutStore.quickActionsMigrationKey)
        let free = AppShortcutStore(defaults: defaults)
        check(free.action(matching: event) == .openQuickActions, "unoccupied legacy receives default once")
        free.resetAll()
        check(free.action(matching: event) == .openQuickActions && free.shortcut(for: .findTerminal) != nil, "reset all retains original actions")
        let many = (0..<1050).map { index in
            QuickActionItem(id: index < 1000 ? .host(UUID()) : .session(UUID()), section: index < 1000 ? .hosts : .sessions, title: "Server \(index)", detail: "ops@192.0.2.1", hint: "", symbol: "", keywords: "Group \(index % 10)")
        }
        var timings: [Double] = []
        for i in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            _ = QuickActionSearch.results(many, query: i % 2 == 0 ? "server 1" : "")
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        check(QuickActionSearch.results(many, query: "server").count == 1050, "all search matches remain reachable")
        check(QuickActionSearch.results(many, query: "").filter { $0.section == .hosts }.count == 6, "empty query limits recent hosts without hiding operations")
        print("1,000 hosts / 50 sessions search p95: \(timings.sorted()[94]) ms")
        print("\(passed) quick action tests passed, 0 failed")
    }
}
