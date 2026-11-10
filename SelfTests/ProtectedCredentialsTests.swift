import AppKit
import Foundation

@MainActor private final class FakeClock { var value: TimeInterval = 100 }
@MainActor private final class FakeAuthentication: LocalUserAuthenticating {
    var replies: [(Result<Void, LocalUserAuthenticationError>) -> Void] = []
    var cancellations = 0
    func authenticate(_ completion: @escaping (Result<Void, LocalUserAuthenticationError>) -> Void) { replies.append(completion) }
    func cancel() { cancellations += 1 }
    func complete(_ index: Int = 0, _ result: Result<Void, LocalUserAuthenticationError> = .success(())) { replies[index](result) }
}
@MainActor private final class FakePasteboard: SensitivePasteboard {
    var changeCount = 0
    var ownerMarker: String?
    var value: String?
    var writes = 0
    var clears = 0
    var failWrite = false
    var failAfterWrite = false
    func write(_ string: String, marker: String) -> Bool {
        writes += 1
        guard !failWrite else { return false }
        changeCount += 1; value = string; ownerMarker = marker
        return !failAfterWrite
    }
    func clear() { clears += 1; changeCount += 1; value = nil; ownerMarker = nil }
    func userCopies(_ string: String) { changeCount += 1; value = string; ownerMarker = nil }
}
@MainActor private final class Harness {
    let clock = FakeClock()
    let authentication = FakeAuthentication()
    let board = FakePasteboard()
    let clipboard: SensitiveClipboardStore
    let store: ProtectedCredentialsStore
    var active = true
    var reads: [(UUID, (Result<Data?, Error>) -> Void)] = []
    static var host: HostProfile {
        var host = HostProfile()
        host.id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        host.hostname = "synthetic.invalid"
        host.username = "fixture"
        return host
    }
    init() {
        let clock = clock
        clipboard = SensitiveClipboardStore(pasteboard: board, now: { clock.value }, schedulesTimer: false)
        // A proxy avoids capturing a partially initialized harness.
        var read: ProtectedCredentialsStore.PasswordReader = { _, _ in nil }
        store = ProtectedCredentialsStore(authentication: authentication, clipboard: clipboard,
            now: { clock.value }, schedulesTimer: false, readPassword: { id, complete in read(id, complete) })
        read = { [weak self] id, complete in self?.reads.append((id, complete)); return nil }
        store.setBoundary { [weak self] in self?.active == true }
        store.updateHosts([Self.host])
    }
    func open() { store.setVisible(true) }
    func unlock() { open(); authentication.complete(authentication.replies.count - 1); store.select(hostID: Self.host.id) }
    func answer(_ index: Int = 0, value: String = " synthetic 中文 ' $ value ") { reads[index].1(.success(Data(value.utf8))) }
}

@main struct ProtectedCredentialsTests {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        var policy = ProtectedCredentialsPolicy()
        expect(!policy.permitsAccess(at: 100), "Locked policy grants access")
        let first = policy.beginAuthentication()
        policy.lock()
        expect(!policy.completeAuthentication(first, succeeded: true, now: 100), "Cancelled authentication revived")
        let second = policy.beginAuthentication()
        expect(policy.completeAuthentication(second, succeeded: true, now: 100), "Current authentication rejected")
        expect(!policy.completeAuthentication(second, succeeded: true, now: 101), "Replayed reply accepted")
        expect(policy.permitsAccess(at: 159.99) && !policy.permitsAccess(at: 160), "Idle deadline wrong")
        expect(!policy.permitsAccess(at: 99) && !policy.permitsAccess(at: .nan), "Invalid clock grants access")
        for time in stride(from: 150.0, through: 350.0, by: 50.0) { policy.recordInteraction(at: time) }
        expect(policy.permitsAccess(at: 399.99) && !policy.permitsAccess(at: 400), "Absolute deadline extended by activity")

        expect(ProtectedCredentialsFocusPolicy.isSystemAuthenticationAgent(
            bundleID: "com.apple.LocalAuthentication.UIAgent",
            executablePath: "/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle/Contents/MacOS/coreautha"),
            "System authentication agent cannot own temporary focus")
        expect(!ProtectedCredentialsFocusPolicy.isSystemAuthenticationAgent(
            bundleID: "com.apple.LocalAuthentication.UIAgent", executablePath: "/Applications/Impersonator.app/Contents/MacOS/coreautha"),
            "Bundle ID alone trusted as system authentication")
        expect(!ProtectedCredentialsFocusPolicy.isSystemAuthenticationAgent(bundleID: "com.apple.finder", executablePath: nil),
            "Other or unknown app treated as authentication")
        do {
            let h = Harness(); h.open()
            h.active = false
            h.store.focusTemporarilyLost("synthetic app resign")
            h.store.focusTemporarilyLost("synthetic window resign")
            expect(h.store.isAuthenticating && h.authentication.cancellations == 0,
                   "System dialog focus transition cancels its own authentication")
            h.authentication.complete()
            expect(!h.store.isUnlocked && h.store.isAuthenticating && h.reads.isEmpty,
                   "Successful LA callback grants access while backgrounded")
            h.clock.value += 1
            h.active = true; h.store.boundaryReady()
            expect(h.store.isUnlocked && !h.store.isAuthenticating, "Valid return from system dialog cannot unlock")
            h.store.focusTemporarilyLost("synthetic later blur")
            expect(!h.store.isUnlocked, "Already-unlocked page ignores focus loss")
        }
        for interruptedAfterSuccess in [false, true] {
            for event in ["other application", "other MyTerm window", "screen lock", "sleep"] {
                let h = Harness(); h.open(); h.active = false
                h.store.focusTemporarilyLost("synthetic auth dialog")
                if interruptedAfterSuccess { h.authentication.complete() }
                h.store.lifecycleEvent(event, clearClipboard: true)
                if !interruptedAfterSuccess { h.authentication.complete() }
                h.active = true; h.store.boundaryReady(); h.store.tick()
                expect(!h.store.isUnlocked && !h.store.isAuthenticating && h.reads.isEmpty,
                       "Real interruption revived pending authentication")
            }
        }
        do {
            let h = Harness(); h.open(); h.active = false; h.authentication.complete()
            h.store.setVisible(false); h.active = true; h.store.boundaryReady()
            expect(!h.store.isUnlocked, "Pending success survives navigation")
        }
        do {
            let h = Harness(); h.open(); h.active = false; h.authentication.complete()
            h.clock.value += ProtectedCredentialsPolicy.authenticationReturnDuration
            h.active = true; h.store.boundaryReady()
            expect(!h.store.isUnlocked && !h.store.isAuthenticating, "Focus return deadline can be renewed")
        }
        do {
            let h = Harness(); h.open(); h.active = false
            h.store.focusTemporarilyLost("synthetic authentication focus")
            h.authentication.complete(0, .failure(.cancelled))
            h.active = true; h.store.boundaryReady()
            expect(!h.store.isUnlocked && !h.store.isAuthenticating, "OS cancellation during handoff ignored")
        }

        do {
            let h = Harness()
            h.store.select(hostID: Harness.host.id); h.store.reveal(); h.store.copyPassword()
            expect(h.reads.isEmpty && h.board.writes == 0, "Unauthenticated read/copy")
            h.open(); h.open(); h.store.unlock()
            expect(h.authentication.replies.count == 1, "Duplicate authentication prompts")
            h.authentication.complete(0, .failure(.cancelled))
            expect(!h.store.isUnlocked && h.store.message == nil, "Cancellation grants access or shows error")
            h.store.unlock(); h.authentication.complete(1, .failure(.unavailable))
            expect(!h.store.isUnlocked && h.store.message != nil, "Unavailable authentication not handled")
        }
        do {
            let h = Harness(); h.open(); h.store.setVisible(false); h.authentication.complete()
            expect(!h.store.isUnlocked && h.reads.isEmpty, "Late authentication unlocked hidden page")
            h.open(); h.authentication.complete(0)
            expect(!h.store.isUnlocked, "Old reply unlocks new attempt")
            h.authentication.complete(1)
            expect(h.store.isUnlocked, "New attempt cannot complete")
            h.active = false; h.store.copyPassword()
            expect(!h.store.isUnlocked && h.reads.isEmpty, "Inactive window can read")
        }
        do {
            let h = Harness(); h.unlock()
            expect(h.reads.isEmpty, "Selecting a row reads credentials eagerly")
            h.store.reveal(); h.store.reveal()
            expect(h.reads.count == 1, "Duplicate in-flight reads")
            h.answer()
            expect(h.store.revealedPassword == " synthetic 中文 ' $ value ", "Secret normalized or truncated")
            h.clock.value += 30; h.store.tick()
            expect(h.store.revealedPassword == nil && h.store.isUnlocked, "Reveal expiry did not hide")
            h.store.copyPassword(); h.answer(1)
            expect(h.board.writes == 1 && h.store.revealedPassword == nil, "Copy requires or exposes plaintext")
            h.store.setVisible(false)
            expect(h.board.value != nil && !h.store.isUnlocked, "Leaving page prevents terminal paste")
            h.clock.value += 30; h.clipboard.tick()
            expect(h.board.value == nil, "Clipboard expiry depends on visible page")
        }
        do {
            let h = Harness(); h.unlock(); h.store.reveal(); h.store.setVisible(false); h.answer()
            expect(h.store.revealedPassword == nil && h.board.writes == 0, "Late read exposed hidden data")
        }
        do {
            let h = Harness(); h.unlock(); h.store.copyPassword()
            h.clock.value += 60; h.answer()
            expect(h.board.writes == 0 && !h.store.isUnlocked, "Read completion bypasses deadline")
        }
        do {
            let h = Harness(); h.unlock(); h.store.reveal()
            h.store.passwordDidChange(hostID: Harness.host.id); h.answer()
            expect(h.store.revealedPassword == nil && !h.store.isUnlocked, "Changed password completed stale read")
        }
        for mutation in 0..<5 {
            let h = Harness(); h.unlock(); h.store.copyPassword()
            var changed = Harness.host
            switch mutation {
            case 0: changed.hostname = "other.invalid"
            case 1: changed.username = "other"
            case 2: changed.port = 2222
            case 3: changed.authenticationMethod = .privateKey
            default: break
            }
            h.store.updateHosts(mutation == 4 ? [] : [changed]); h.answer()
            expect(!h.store.isUnlocked && h.board.writes == 0, "Identity mutation retained authority")
        }
        do {
            let h = Harness(); h.unlock()
            var renamed = Harness.host; renamed.name = "Renamed"; renamed.updatedAt = .now
            h.store.updateHosts([renamed]); h.store.passwordDidChange(hostID: UUID())
            expect(h.store.isUnlocked && h.store.selectedHost?.name == "Renamed", "Unrelated metadata revokes access")
            h.store.reveal(); h.reads[0].1(.success(nil))
            expect(h.store.revealedPassword == nil && h.store.message?.contains("尚未儲存") == true, "Missing password is not a normal empty state")
            h.store.reveal(); h.reads[1].1(.success(Data([0xff, 0xfe])))
            expect(h.store.revealedPassword == nil && h.store.message?.contains("無法讀取") == true, "Invalid bytes are displayed lossily")
            h.store.reveal()
            h.reads[2].1(.failure(NSError(domain: "synthetic-secret-in-error", code: 1)))
            expect(h.store.message?.contains("synthetic-secret") == false && h.store.revealedPassword == nil,
                   "Storage error exposed raw contents")
        }
        for method: AuthenticationMethod in [.privateKey, .sshAgent] {
            let h = Harness(); var host = Harness.host; host.authenticationMethod = method
            h.store.updateHosts([host]); h.open(); h.authentication.complete(); h.store.select(hostID: host.id)
            h.store.reveal(); h.store.copyPassword()
            expect(h.reads.isEmpty, "Non-password authentication exposes old password")
        }
        do {
            let h = Harness(); var host = Harness.host; host.username = ""
            h.store.updateHosts([host]); h.open(); h.authentication.complete(); h.store.select(hostID: host.id)
            h.store.reveal(); expect(h.reads.isEmpty, "Unbound account can read password")
        }
        do {
            let h = Harness(); let source = ProtectedCredentialIdentity(Harness.host)
            expect(h.clipboard.copy("first", source: source), "Copy failed")
            h.clock.value += 20; h.clipboard.copy("second", source: source)
            h.clock.value += 10; h.clipboard.tick()
            expect(h.board.value == "second", "Earlier deadline cleared newer copy")
            h.board.userCopies("user text"); h.clock.value += 30; h.clipboard.tick()
            expect(h.board.value == "user text", "Expiry erased user copy")
            h.clipboard.copy("third", source: source); h.board.userCopies("next")
            h.clipboard.clearOwnedContent()
            expect(h.board.value == "next", "Manual lock erased subsequent clipboard content")
            h.board.failWrite = true
            expect(!h.clipboard.copy("failed", source: source), "Failed pasteboard write reported success")
            h.board.failWrite = false; h.board.failAfterWrite = true
            expect(!h.clipboard.copy("partial failure", source: source) && h.board.value == nil,
                   "Partial failed write left a password without cleanup")
        }
        do {
            let h = Harness(); h.unlock(); h.store.copyPassword(); h.answer()
            h.store.setVisible(false); h.store.passwordDidChange(hostID: Harness.host.id)
            expect(h.board.value == nil, "Hidden page left replaced password on clipboard")
            h.clipboard.copy("test", source: ProtectedCredentialIdentity(Harness.host))
            h.clipboard.reconcile(hosts: [])
            expect(h.board.value == nil, "Deleted host left owned clipboard content")
        }
        do {
            let h = Harness(); h.unlock(); h.store.reveal(); h.answer()
            h.store.lifecycleEvent("synthetic sleep", clearClipboard: true)
            expect(h.store.revealedPassword == nil && !h.store.isUnlocked, "System interruption did not lock")
            let other = Harness(); other.open()
            expect(!other.store.isUnlocked, "Authentication shared between windows")
        }
        do {
            let h = Harness(); h.unlock()
            expect(h.store.visibleHosts.count == 1 && h.reads.isEmpty, "List reads a password eagerly")
            h.store.setSearchText("FIXTURE")
            expect(h.store.visibleHosts.count == 1 && h.reads.isEmpty, "Account search is not case-insensitive metadata-only")
            h.store.reveal(); h.store.setSearchText("no-match")
            h.answer()
            expect(h.store.selectedHost == nil && h.store.revealedPassword == nil && h.store.visibleHosts.isEmpty,
                   "Filtered-out selection accepted late secret")
            h.store.lock()
            expect(h.store.searchText.isEmpty && h.store.visibleHosts.isEmpty, "Lock retains page search/results")
            h.store.setSearchText("not allowed")
            expect(h.store.searchText.isEmpty, "Locked search mutates page")
        }
        do {
            let h = Harness(); h.unlock()
            expect(h.store.metadataForCopy(.account) == "fixture", "Account copy failed")
            expect(h.store.metadataForCopy(.address) == "synthetic.invalid:22", "Address copy failed")
            h.store.lock()
            expect(h.store.metadataForCopy(.account) == nil, "Locked metadata action bypasses page guard")
        }
        do {
            var first = Harness.host; first.name = "主機2"
            var second = Harness.host; second.id = UUID(); second.name = "主機10"
            let result = ProtectedCredentialsList.filtered([second, first], query: " 主機 ")
            expect(result.map(\.name) == ["主機2", "主機10"], "Natural ordering or trimmed query failed")
            expect(ProtectedCredentialsList.filtered([first], query: "22").count == 1, "Port search failed")
        }
        do {
            let center = NotificationCenter()
            let notification = Notification.Name("MyTerm.Credentials.UnitChange")
            let tracker = CredentialChangeTracker(notification: notification, center: center)
            let h = Harness()
            h.store.setSourceIdentity(currentHost: { $0 == Harness.host.id ? Harness.host : nil },
                                      revision: { tracker.generation(for: $0) })
            h.unlock(); h.store.copyPassword()
            let changed = DispatchSemaphore(value: 0)
            let changedID = Harness.host.id
            DispatchQueue.global().async {
                center.post(name: notification, object: changedID)
                changed.signal()
            }
            expect(changed.wait(timeout: .now() + 2) == .success, "Background change was not delivered")
            h.answer()
            expect(!h.store.isUnlocked && h.board.writes == 0, "Pending UI notification permits stale password")
            expect(tracker.generation(for: UUID()) == 0, "Change tracker invalidates unrelated host")
        }
        do {
            let h = Harness()
            var current: HostProfile? = Harness.host
            h.store.setSourceIdentity(currentHost: { _ in current }, revision: { _ in 0 })
            h.unlock(); h.store.reveal()
            current = nil // HostStore changes before the next SwiftUI refresh.
            h.answer()
            expect(!h.store.isUnlocked && h.store.revealedPassword == nil, "Live source deletion ignored")
        }
        do {
            let queue = DispatchQueue(label: "MyTerm.Credentials.CancelledReadTest")
            queue.suspend()
            let request = ProtectedCredentialReadRequest.start(hostID: Harness.host.id, queue: queue,
                load: { _ in preconditionFailure("Cancelled queued work reached the vault") },
                complete: { _ in preconditionFailure("Cancelled work returned a result") })
            request.cancel()
            queue.resume()
            queue.sync { }
            expect(request.isCancelled, "Queued read cannot be cancelled")
        }
        do {
            let queue = DispatchQueue(label: "MyTerm.Credentials.LateReadTest")
            let loaded = DispatchSemaphore(value: 0)
            var returned = false
            let request = ProtectedCredentialReadRequest.start(hostID: Harness.host.id, queue: queue,
                load: { _ in loaded.signal(); return Data("late synthetic".utf8) },
                complete: { _ in returned = true })
            expect(loaded.wait(timeout: .now() + 2) == .success, "Reader did not start")
            queue.sync { }
            request.cancel()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            expect(!returned, "Cancelled background result reached the page")
        }
        // Named pasteboard never reads or replaces the user's general clipboard.
        let board = NSPasteboard(name: .init("MyTerm-Credentials-Test-" + UUID().uuidString))
        defer { board.clearContents(); board.releaseGlobally() }
        let adapter = SystemSensitivePasteboard(board)
        let clock = FakeClock()
        let clipboard = SensitiveClipboardStore(pasteboard: adapter, now: { clock.value }, schedulesTimer: false)
        let source = ProtectedCredentialIdentity(Harness.host)
        expect(clipboard.copy("native synthetic", source: source), "Native named pasteboard write failed")
        expect(board.string(forType: .string) == "native synthetic" && adapter.ownerMarker != nil, "Native item/owner absent")
        clock.value += 30; clipboard.tick()
        expect(board.string(forType: .string) == nil, "Native expiry failed")
        clipboard.copy("native second", source: source)
        board.clearContents(); board.setString("native user copy", forType: .string)
        clipboard.clearOwnedContent()
        expect(board.string(forType: .string) == "native user copy", "Native ownership check failed")
        print("Protected credentials: \(checks) checks passed (synthetic data/private pasteboard; no authentication prompts or vault access).")
    }
}
