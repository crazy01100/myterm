import AppKit

@MainActor
protocol SensitivePasteboard: AnyObject {
    var changeCount: Int { get }
    var ownerMarker: String? { get }
    func write(_ string: String, marker: String) -> Bool
    func clear()
}

@MainActor
final class SystemSensitivePasteboard: SensitivePasteboard {
    static let ownerType = NSPasteboard.PasteboardType("tw.local.MySSHClient.credential-owner")
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    var changeCount: Int { pasteboard.changeCount }
    var ownerMarker: String? { pasteboard.string(forType: Self.ownerType) }

    func write(_ string: String, marker: String) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(string, forType: .string),
              item.setString(marker, forType: Self.ownerType) else { return false }
        pasteboard.prepareForNewContents(with: [.currentHostOnly])
        return pasteboard.writeObjects([item])
    }

    func clear() { pasteboard.clearContents() }
}

/// App-lifetime ownership, independent of the lifetime of the credentials page.
/// The lease retains identity and an opaque marker, never a second password copy.
@MainActor
final class SensitiveClipboardStore {
    private struct Lease {
        let source: ProtectedCredentialIdentity
        let marker: String
        let changeCount: Int
        let deadline: TimeInterval
    }
    private let pasteboard: SensitivePasteboard
    private let now: () -> TimeInterval
    private let schedulesTimer: Bool
    private var lease: Lease?
    private var timer: Timer?
    private var notifications: [(NotificationCenter, NSObjectProtocol)] = []

    init(pasteboard: SensitivePasteboard, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedulesTimer: Bool = true, observeSystem: Bool = false) {
        self.pasteboard = pasteboard
        self.now = now
        self.schedulesTimer = schedulesTimer
        if observeSystem {
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                         NSWorkspace.sessionDidResignActiveNotification] {
                observe(name, center: workspace) { $0.clearOwnedContent() }
            }
            observe(NSApplication.willTerminateNotification, center: .default) { $0.clearOwnedContent() }
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
                observe(name, center: workspace) { $0.tick() }
            }
            observe(NSApplication.didBecomeActiveNotification, center: .default) { $0.tick() }
        }
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter,
                         action: @escaping (SensitiveClipboardStore) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // NotificationCenter's .main queue serializes these callbacks with pasteboard writes.
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        notifications.append((center, token))
    }

    @discardableResult
    func copy(_ value: String, source: ProtectedCredentialIdentity) -> Bool {
        clearOwnedContent()
        let marker = UUID().uuidString
        let wrote = pasteboard.write(value, marker: marker)
        let count = pasteboard.changeCount
        guard wrote, pasteboard.ownerMarker == marker else {
            // A failed writer may have published part of the item. Clear only
            // our own new item, never a concurrent replacement by another app.
            if pasteboard.ownerMarker == marker && pasteboard.changeCount == count { pasteboard.clear() }
            return false
        }
        lease = Lease(source: source, marker: marker, changeCount: pasteboard.changeCount,
                      deadline: now() + ProtectedCredentialsPolicy.clipboardDuration)
        if schedulesTimer {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        return true
    }

    func tick() {
        guard let lease else { return }
        if !owns(lease) { abandonLease(); return }
        if now() >= lease.deadline { clearOwnedContent() }
    }

    func invalidate(hostID: UUID) {
        if lease?.source.hostID == hostID { clearOwnedContent() }
    }

    func reconcile(hosts: [HostProfile]) {
        guard let source = lease?.source else { return }
        guard let current = hosts.first(where: { $0.id == source.hostID }),
              ProtectedCredentialIdentity(current) == source else { clearOwnedContent(); return }
    }

    func clearOwnedContent() {
        if let lease, owns(lease) { pasteboard.clear() }
        abandonLease()
    }

    private func owns(_ lease: Lease) -> Bool {
        pasteboard.changeCount == lease.changeCount && pasteboard.ownerMarker == lease.marker
            && pasteboard.changeCount == lease.changeCount
    }

    private func abandonLease() {
        timer?.invalidate()
        timer = nil
        lease = nil
    }

    deinit {
        timer?.invalidate()
        for (center, token) in notifications { center.removeObserver(token) }
    }
}
