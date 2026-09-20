import Foundation

@MainActor
private final class ConnectionSpy: SFTPHostOpeningConnection {
    var target: SFTPConnectionTarget?
    var generation = UUID()
    var busy = false
    var calls: [(HostProfile, String)] = []
    var openingSnapshot: SFTPConnectionSnapshot {
        SFTPConnectionSnapshot(target: target, generation: generation, isBusy: busy, description: "Test connection")
    }
    func connect(to host: HostProfile, username: String) {
        calls.append((host, username))
        target = SFTPConnectionTarget(host: host, username: username)
        generation = UUID()
    }
}

@main
struct SFTPHostOpeningTests {
    @MainActor
    static func main() throws {
        var count = 0
        func check(_ result: @autoclosure () -> Bool, _ message: String) {
            guard result() else { fatalError("FAIL: \(message)") }
            count += 1
            print("PASS: \(message)")
        }
        var host = HostProfile()
        host.hostname = "192.0.2.10"
        host.username = "ops"
        host.port = 2222
        host.authenticationMethod = .sshAgent
        var other = host
        other.id = UUID()
        other.username = "admin"
        var hosts = [host, other]
        let connection = ConnectionSpy()
        let controller = SFTPHostOpeningController()
        var shown = 0
        func open(_ profile: HostProfile) {
            controller.begin(host: profile, hosts: hosts, connection: connection) { shown += 1 }
        }
        func confirm() {
            controller.confirmSwitch(hosts: hosts, connection: connection) { shown += 1 }
        }
        open(host)
        check(connection.calls.count == 1 && shown == 1, "first request connects and shows workspace")
        check(connection.calls[0].0 == host && connection.calls[0].1 == "ops", "exact host settings and account forwarded")
        open(host)
        check(connection.calls.count == 1 && shown == 2, "same active target reused without reconnect")
        connection.busy = true
        open(host)
        check(connection.calls.count == 1 && shown == 3 && controller.notice == nil, "same busy target can be shown without cancelling work")
        open(other)
        check(connection.calls.count == 1 && controller.notice != nil && controller.switchConfirmation == nil, "busy target switch rejected before disconnect")
        controller.notice = nil
        connection.busy = false
        open(other)
        check(controller.switchConfirmation != nil && connection.calls.count == 1, "different account at same address requires confirmation")
        controller.switchConfirmation = nil
        check(connection.target == SFTPConnectionTarget(host: host, username: host.username), "cancel keeps original connection")
        open(other)
        connection.busy = true
        confirm()
        check(controller.notice != nil && connection.calls.count == 1, "work starting after confirmation is rechecked")
        controller.notice = nil
        connection.busy = false
        open(other)
        connection.generation = UUID()
        confirm()
        check(controller.notice != nil && connection.calls.count == 1, "replaced connection invalidates earlier confirmation")
        controller.notice = nil
        open(other)
        hosts[1].port = 2200
        confirm()
        check(controller.notice != nil && connection.calls.count == 1, "target edit during confirmation cannot silently change destination")
        controller.notice = nil
        hosts[1] = other
        open(other)
        hosts.removeLast()
        confirm()
        check(controller.notice != nil && connection.calls.count == 1, "deleted target cannot connect from saved confirmation")
        controller.notice = nil
        hosts.append(other)
        open(other)
        open(host)
        check(controller.switchConfirmation?.request.host.id == other.id, "pending confirmation cannot be overwritten by another click")
        confirm()
        check(connection.calls.count == 2 && shown == 4 && connection.target == SFTPConnectionTarget(host: other, username: other.username), "confirmed idle switch connects exactly once")
        confirm()
        check(connection.calls.count == 2, "repeated confirmation is a no-op")

        // Presentation metadata must not reset a live directory or connection.
        var renamed = other
        renamed.name = "Renamed"
        renamed.notes = "new note"
        renamed.groupID = UUID()
        renamed.detectedPlatform = .debian
        renamed.updatedAt = .distantFuture
        hosts[1] = renamed
        open(renamed)
        check(connection.calls.count == 2 && shown == 5, "metadata-only changes reuse connection")
        let original = SFTPConnectionTarget(host: other, username: other.username)
        let changes: [(String, (inout HostProfile) -> Void)] = [
            ("ID", { $0.id = UUID() }), ("hostname", { $0.hostname = "192.0.2.11" }),
            ("port", { $0.port = 2200 }), ("saved username", { $0.username = "new" }),
            ("authentication", { $0.authenticationMethod = .privateKey }),
            ("key path", { $0.privateKeyPath = "/test/key" }),
            ("algorithm mode", { $0.algorithmMode = .custom }),
            ("host key algorithms", { $0.customAlgorithms.hostKeyAlgorithms = "ssh-ed25519" }),
            ("public key algorithms", { $0.customAlgorithms.publicKeyAlgorithms = "ssh-ed25519" }),
            ("key exchange", { $0.customAlgorithms.keyExchangeAlgorithms = "curve25519-sha256" }),
            ("ciphers", { $0.customAlgorithms.ciphers = "aes128-ctr" })
        ]
        for (name, mutate) in changes {
            var changed = other
            mutate(&changed)
            check(SFTPConnectionTarget(host: changed, username: other.username) != original, "connection identity includes \(name)")
        }
        check(SFTPConnectionTarget(host: other, username: "different") != original, "effective account is distinct from saved account")

        var empty = host
        empty.id = UUID()
        empty.username = ""
        hosts.append(empty)
        open(empty)
        check(controller.usernameHost?.id == empty.id && connection.calls.count == 2, "missing username requests input without switching")
        controller.usernameDismissed(hosts: hosts, connection: connection) { shown += 1 }
        check(connection.calls.count == 2 && shown == 5, "username cancellation has no side effects")
        open(empty)
        do { try controller.submitUsername("-o bad"); check(false, "invalid username must throw") }
        catch { check(true, "invalid username rejected before queuing request") }
        try controller.submitUsername(" guest ")
        check(connection.calls.count == 2 && controller.switchConfirmation == nil, "submission waits for sheet dismissal")
        controller.usernameDismissed(hosts: hosts, connection: connection) { shown += 1 }
        check(controller.switchConfirmation?.request.username == "guest", "trimmed username continues after sheet dismissal")
        confirm()
        check(connection.calls.count == 3 && connection.calls.last?.1 == "guest" && hosts.last?.username == "", "one-time username connects without editing inventory")
        controller.usernameDismissed(hosts: hosts, connection: connection) { shown += 1 }
        check(connection.calls.count == 3, "duplicate dismissal cannot replay request")

        // Failed/disconnected snapshots expose no active target; retry is allowed.
        connection.target = nil
        open(host)
        check(connection.calls.count == 4, "inactive or failed connection permits retry")
        var changed = host
        changed.hostname = "192.0.2.12"
        hosts[0] = changed
        open(host)
        check(controller.notice != nil && connection.calls.count == 4, "stale card cannot connect modified target")
        controller.notice = nil
        hosts.removeAll()
        open(host)
        check(controller.notice != nil && connection.calls.count == 4, "removed card cannot open a connection")
        controller.notice = nil
        var invalid = host
        invalid.port = 0
        hosts = [invalid]
        open(invalid)
        check(controller.notice != nil && connection.calls.count == 4, "invalid inventory settings rejected without disconnect")
        print("\(count) SFTP host opening tests passed, 0 failed")
    }
}
