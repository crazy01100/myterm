import Foundation

@main struct CommandSnippetTests {
    static var passed = 0
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAIL: \(message)") }
        passed += 1; print("PASS: \(message)")
    }
    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); check(false, message) } catch { check(true, message) }
    }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyTerm-snippets-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private/snippets.json")
        let store = CommandSnippetStore(fileURL: url)
        check(store.snippets.isEmpty && store.loadError == nil, "missing file starts empty")
        var snippet = CommandSnippet(title: " 磁碟空間 ", command: "df -h", category: " 系統 ", note: "查看使用量")
        try store.save(snippet)
        check(store.snippets.first?.title == "磁碟空間" && store.snippets.first?.category == "系統", "save normalizes names without changing command")
        check(store.snippets.first?.command == "df -h", "save never executes or modifies command text")
        let disk = try Data(contentsOf: url)
        let restored = CommandSnippetStore(fileURL: url)
        check(restored.snippets == store.snippets, "relaunch restores saved snippets")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "snippet file is private before publication")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        check((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "snippet directory is owner-only")
        snippet.command = "uptime"; try store.save(snippet)
        check(store.snippets.count == 1 && store.snippets[0].command == "uptime", "editing preserves identity")
        rejects("empty name rejected") { try store.save(CommandSnippet(title: " ", command: "pwd")) }
        rejects("empty command rejected") { try store.save(CommandSnippet(title: "test", command: " \n")) }
        rejects("oversized command rejected") { try store.save(CommandSnippet(title: "test", command: String(repeating: "a", count: 16_385))) }
        let failing = CommandSnippetStore(fileURL: url, persist: { _,_ in throw CocoaError(.fileWriteNoPermission) })
        rejects("failed save reports error") { try failing.save(CommandSnippet(title: "new", command: "pwd")) }
        check(failing.snippets == store.snippets, "failed save does not mutate memory")
        rejects("failed delete reports error") { try failing.delete(snippet.id) }
        check(failing.snippets == store.snippets, "failed delete retains snippet")
        try store.delete(snippet.id)
        check(CommandSnippetStore(fileURL: url).snippets.isEmpty, "deletion persists")
        let corrupt = Data("{bad".utf8); try corrupt.write(to: url)
        let broken = CommandSnippetStore(fileURL: url)
        check(broken.loadError != nil, "corrupt file is surfaced")
        rejects("corrupt source cannot be overwritten by new edits") { try broken.save(snippet) }
        check(try Data(contentsOf: url) == corrupt, "corrupt original remains byte-for-byte intact")
        try disk.write(to: url); broken.reload()
        check(broken.loadError == nil && broken.snippets.count == 1, "repaired file can be reloaded without restart")
        let future = try JSONEncoder().encode(CommandSnippetDocument(schemaVersion: 99, snippets: []))
        try future.write(to: url)
        let newer = CommandSnippetStore(fileURL: url)
        rejects("future schema is read-only") { try newer.save(snippet) }
        check(try Data(contentsOf: url) == future, "future schema is not downgraded")
        let crowded = (0..<500).map { CommandSnippet(title: "item \($0)", command: "pwd") }
        try JSONEncoder().encode(CommandSnippetDocument(snippets: crowded)).write(to: url)
        let full = CommandSnippetStore(fileURL: url)
        check(full.snippets.count == 500, "maximum record count loads")
        rejects("record count limit rejects new entry") { try full.save(snippet) }
        try full.save(CommandSnippet(id: crowded[0].id, title: "edited", command: "uptime"))
        check(full.snippets.count == 500 && full.snippets.first?.title == "edited", "existing entry remains editable at limit")
        try JSONEncoder().encode(CommandSnippetDocument(snippets: [snippet, snippet])).write(to: url)
        check(CommandSnippetStore(fileURL: url).loadError != nil, "duplicate record IDs are rejected")
        let escaped = (0..<170).map { CommandSnippet(title: "escaped \($0)", command: String(repeating: "\u{0}", count: 16_384)) }
        let nearlyFull = try JSONEncoder().encode(CommandSnippetDocument(snippets: escaped))
        check(nearlyFull.count < 16 * 1024 * 1024, "storage boundary fixture remains loadable")
        try nearlyFull.write(to: url)
        let capacity = CommandSnippetStore(fileURL: url)
        rejects("encoded file limit is enforced before publication") { try capacity.save(CommandSnippet(title: "overflow", command: escaped[0].command)) }
        check(try Data(contentsOf: url) == nearlyFull && capacity.snippets.count == 170, "file capacity rejection preserves memory and disk")
        for forbidden in ["pwd\nwhoami", "pwd\r", "\u{1b}[A", "x\t", "x\u{0}", "x\u{85}", "x\u{2028}"] {
            check(!CommandSnippet(title: "test", command: forbidden).canInsert, "multiline/control input rejected")
        }
        check(CommandSnippet(title: "test", command: "printf '中文'").canInsert, "ordinary Unicode single line allowed")
        var prompt = SnippetInputPromptGuard()
        prompt.receive(Array("New pass".utf8)[...]);prompt.receive(Array("word:".utf8)[...])
        check(prompt.isBlocked, "split new-password prompt blocks snippets")
        prompt.userInput(Array("a".utf8)[...]);check(prompt.isBlocked, "partially typed secret remains blocked")
        prompt.userInput([13][...]);prompt.receive(Array("\r\n$ ".utf8)[...]);check(!prompt.isBlocked, "fresh prompt after submission clears guard")
        prompt.receive(Array("Verification code:".utf8)[...]);check(prompt.isBlocked, "OTP prompts block snippet insertion")
        let session = UUID(), attempt = UUID()
        let target = SnippetTargetIdentity(sessionID: session, attemptID: attempt)
        var selection = SnippetTargetSelection()
        selection.select(target)
        check(selection.visibleTarget(currentSessionID: session) == target, "explicit pane selection supplies insertion target")
        let other = SnippetTargetIdentity(sessionID: UUID(), attemptID: UUID())
        check(selection.visibleTarget(currentSessionID: other.sessionID) == nil, "implicit workspace changes do not redirect insertion")
        selection.select(other)
        check(selection.visibleTarget(currentSessionID: other.sessionID) == other, "explicit mouse or keyboard navigation follows the new pane")
        check(selection.visibleTarget(currentSessionID: other.sessionID) == other, "library interaction keeps last selected terminal")
        selection.invalidate(sessionID: session)
        check(selection.target == other, "closing an unrelated pane preserves target")
        selection.invalidate(sessionID: other.sessionID)
        check(selection.visibleTarget(currentSessionID: session) == nil, "closing target never falls back to surviving pane")
        selection.select(target)
        selection.invalidate(sessionID: session)
        check(selection.target == nil, "retry invalidates previous attempt before reconnect")
        let reconnected = SnippetTargetIdentity(sessionID: session, attemptID: UUID())
        selection.select(reconnected)
        check(selection.target == reconnected && selection.target != target, "reselecting after reconnect captures new attempt")
        selection.select(nil)
        check(selection.visibleTarget(currentSessionID: nil) == nil, "library or unsupported terminal clears insertion target")
        check(target.permits(currentSessionID: session, currentAttemptID: attempt, connected: true, supported: true, passwordPrompt: false, alternateScreen: false), "same connected target accepted")
        check(!target.permits(currentSessionID: UUID(), currentAttemptID: attempt, connected: true, supported: true, passwordPrompt: false, alternateScreen: false), "other split pane rejected")
        check(!target.permits(currentSessionID: session, currentAttemptID: UUID(), connected: true, supported: true, passwordPrompt: false, alternateScreen: false), "reconnected same session rejected")
        check(!target.permits(currentSessionID: nil, currentAttemptID: nil, connected: true, supported: true, passwordPrompt: false, alternateScreen: false), "closed or hidden session rejected")
        for flags in [(false,true,false,false),(true,false,false,false),(true,true,true,false),(true,true,false,true)] {
            check(!target.permits(currentSessionID: session, currentAttemptID: attempt, connected: flags.0, supported: flags.1, passwordPrompt: flags.2, alternateScreen: flags.3), "disconnected, Serial, password or alternate screen rejected")
        }
        let suite = "MyTerm-snippet-shortcuts-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = AppShortcutStore(defaults: defaults)
        check(shortcuts.shortcut(for: .openSnippetLibrary) == nil, "new shortcut unassigned by default")
        let commandK = AppShortcutDefinition.command(keyCode: 40, key: "K")
        rejects("existing Command-K not stolen") { try shortcuts.assign(commandK, to: .openSnippetLibrary) }
        try shortcuts.assign(.commandOption(keyCode: 40, key: "K"), to: .openSnippetLibrary)
        check(AppShortcutStore(defaults: defaults).shortcut(for: .openSnippetLibrary) != nil, "custom binding survives relaunch")
        try shortcuts.assign(nil, to: .openSnippetLibrary)
        check(AppShortcutStore(defaults: defaults).shortcut(for: .openSnippetLibrary) == nil, "disabled binding stays disabled")
        try shortcuts.reset(.openSnippetLibrary)
        check(shortcuts.shortcut(for: .openSnippetLibrary) == nil && shortcuts.shortcut(for: .openQuickActions) == commandK, "reset preserves original shortcuts")
        print("\(passed) command snippet checks passed, 0 failed")
    }
}
