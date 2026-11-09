import Combine
import Foundation

/// Authenticated page state. Production supplies an explicit vault reader;
/// isolated tests inject inert readers and never access the user's vault.
@MainActor
final class ProtectedCredentialsStore: ObservableObject {
    typealias PasswordReader = (UUID, @escaping (Result<Data?, Error>) -> Void) -> (() -> Void)?
    @Published private(set) var policy = ProtectedCredentialsPolicy()
    @Published private(set) var selectedHost: HostProfile?
    @Published private(set) var revealedPassword: String?
    @Published private(set) var isReading = false
    @Published private(set) var message: String?
    @Published private(set) var searchText = ""
    @Published private(set) var visibleHosts: [HostProfile] = []
    @Published private(set) var passwordIsMissing = false
    private let authentication: LocalUserAuthenticating
    private let clipboard: SensitiveClipboardStore
    private let readPassword: PasswordReader
    private let now: () -> TimeInterval
    private var hosts: [HostProfile] = []
    private var currentHost: ((UUID) -> HostProfile?)?
    private var revision: (UUID) -> UInt64 = { _ in 0 }
    private var selectedRevision: UInt64?
    private var visible = false
    private var pendingAutomaticUnlock = false
    private var successfulAttempt: (id: UUID, deadline: TimeInterval)?
    private var boundaryIsActive: () -> Bool = { false }
    private var operationID: UUID?
    private var cancelPendingRead: (() -> Void)?
    private var revealDeadline: TimeInterval?
    private var timer: Timer?

    init(authentication: LocalUserAuthenticating, clipboard: SensitiveClipboardStore,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedulesTimer: Bool = true, readPassword: @escaping PasswordReader) {
        self.authentication = authentication
        self.clipboard = clipboard
        self.now = now
        self.readPassword = readPassword
        if schedulesTimer {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    var isUnlocked: Bool { policy.permitsAccess(at: now()) && visible && boundaryIsActive() }
    var isAuthenticating: Bool { policy.attemptID != nil }

    func setBoundary(_ check: @escaping () -> Bool) { boundaryIsActive = check }

    func setSourceIdentity(currentHost: @escaping (UUID) -> HostProfile?, revision: @escaping (UUID) -> UInt64) {
        self.currentHost = currentHost
        self.revision = revision
    }

    func setVisible(_ value: Bool) {
        let entering = value && !visible
        visible = value
        if !value { lock(event: "離開登入資訊") }
        if entering { pendingAutomaticUnlock = true; boundaryReady() }
    }

    func boundaryReady() {
        completeAuthenticationAfterFocusReturn()
        guard pendingAutomaticUnlock, visible, boundaryIsActive() else { return }
        pendingAutomaticUnlock = false
        unlock()
    }

    func unlock() {
        guard visible, boundaryIsActive(), !isAuthenticating, !isUnlocked else { return }
        clearPresentation()
        let attempt = policy.beginAuthentication()
        authentication.authenticate { [weak self] result in
            guard let self, self.policy.attemptID == attempt else { return }
            guard self.visible else { self.lock(event: "驗證回覆時頁面已失效"); return }
            switch result {
            case .success:
                // LA may reply before AppKit restores key-window status. A
                // pending success is not an authorization and expires quickly.
                self.successfulAttempt = (attempt, self.now() + ProtectedCredentialsPolicy.authenticationReturnDuration)
                self.completeAuthenticationAfterFocusReturn()
            case .failure(let error):
                self.lock(event: "系統驗證未完成")
                self.message = error.message
            }
        }
    }

    func lock(event: String = "手動鎖定", clearClipboard: Bool = false) {
        policy.lock()
        successfulAttempt = nil
        pendingAutomaticUnlock = false
        authentication.cancel()
        clearPresentation()
        if clearClipboard { clipboard.clearOwnedContent() }
    }

    func lifecycleEvent(_ name: String, clearClipboard: Bool = false) {
        lock(event: name, clearClipboard: clearClipboard)
    }

    func focusTemporarilyLost(_ name: String) {
        // Opening macOS authentication itself resigns app/key focus. No access
        // exists yet. Actual app activation, navigation and system lifecycle
        // events independently invalidate the request even during this phase.
        if isAuthenticating { return }
        lock(event: name)
    }

    private func completeAuthenticationAfterFocusReturn() {
        guard let successfulAttempt else { return }
        guard policy.attemptID == successfulAttempt.id, visible,
              now() < successfulAttempt.deadline else { lock(event: "驗證返回逾時或已失效"); return }
        guard boundaryIsActive() else { return }
        self.successfulAttempt = nil
        if policy.completeAuthentication(successfulAttempt.id, succeeded: true, now: now()) {
            refreshVisibleHosts()
        }
    }

    func interaction() {
        guard requireAccess() else { return }
        policy.recordInteraction(at: now())
    }

    func updateHosts(_ hosts: [HostProfile]) {
        self.hosts = hosts
        refreshVisibleHosts()
        clipboard.reconcile(hosts: hosts)
        guard let selectedHost else { return }
        guard let current = hosts.first(where: { $0.id == selectedHost.id }),
              ProtectedCredentialIdentity(current) == ProtectedCredentialIdentity(selectedHost) else {
            lock(event: "主機身分變動")
            return
        }
        self.selectedHost = current
        if !visibleHosts.contains(where: { $0.id == current.id }) { clearSelection() }
    }

    func setSearchText(_ text: String) {
        guard requireAccess() else { return }
        searchText = text
        policy.recordInteraction(at: now())
        refreshVisibleHosts()
        if let selectedHost, !visibleHosts.contains(where: { $0.id == selectedHost.id }) { clearSelection() }
    }

    private func refreshVisibleHosts() {
        visibleHosts = policy.authorizationID == nil ? [] : ProtectedCredentialsList.filtered(hosts, query: searchText)
    }

    func passwordDidChange(hostID: UUID) {
        clipboard.invalidate(hostID: hostID)
        if selectedHost?.id == hostID { lock(event: "登入密碼變動") }
    }

    func select(hostID: UUID) {
        guard requireAccess(), visibleHosts.contains(where: { $0.id == hostID }),
              let host = latestHost(hostID) else { return }
        cancelRead()
        hidePassword()
        message = nil
        selectedHost = host
        selectedRevision = revision(hostID)
        passwordIsMissing = false
        policy.recordInteraction(at: now())
    }

    func reveal() { readSelected(copying: false) }
    func copyPassword() { readSelected(copying: true) }
    func deselect() { clearSelection() }

    func hidePassword() {
        revealedPassword = nil
        revealDeadline = nil
    }

    enum MetadataField { case account, address }
    func metadataForCopy(_ field: MetadataField) -> String? {
        guard requireAccess(), let host = selectedHost else { return nil }
        policy.recordInteraction(at: now())
        return field == .account ? host.username : "\(host.hostname):\(host.port)"
    }

    func tick() {
        completeAuthenticationAfterFocusReturn()
        if policy.authorizationID != nil, !isUnlocked { lock(event: "授權或頁面期限失效") }
        if policy.authorizationID != nil { _ = selectedIdentityIsCurrent() }
        if let revealDeadline, now() >= revealDeadline { hidePassword() }
    }

    private func readSelected(copying: Bool) {
        guard requireAccess(), !isReading, let selectedHost else { return }
        let identity = ProtectedCredentialIdentity(selectedHost)
        guard identity.canReadPassword else { message = "此主機目前不提供登入密碼查看。"; return }
        policy.recordInteraction(at: now())
        let authorization = policy.authorizationID
        let sourceRevision = revision(identity.hostID)
        let operation = UUID()
        operationID = operation
        isReading = true
        message = nil
        let cancellation = readPassword(identity.hostID) { [weak self] result in
            // Readers must deliver on the main actor, allowing a final atomic UI authorization check.
            guard let self else { return }
            guard self.operationID == operation else { return }
            self.cancelRead()
            guard self.requireAccess(), self.policy.authorizationID == authorization,
                  self.selectedHost.map(ProtectedCredentialIdentity.init) == identity,
                  self.latestHost(identity.hostID).map(ProtectedCredentialIdentity.init) == identity,
                  self.revision(identity.hostID) == sourceRevision else { return }
            switch result {
            case .success(var data):
                defer { if data != nil { data!.resetBytes(in: data!.indices) } }
                guard let value = data else {
                    self.hidePassword()
                    self.passwordIsMissing = true
                    self.message = "這台主機尚未儲存登入密碼。"; return
                }
                guard let text = String(data: value, encoding: .utf8) else {
                    self.hidePassword()
                    self.message = "登入密碼資料無法讀取。"; return
                }
                self.passwordIsMissing = false
                if copying {
                    self.message = self.clipboard.copy(text, source: identity)
                        ? "已複製，30 秒後清除。" : "無法複製，請重試。"
                } else {
                    self.revealedPassword = text
                    self.revealDeadline = self.now() + ProtectedCredentialsPolicy.revealDuration
                }
            case .failure:
                // No raw errors from credential storage in logs, alerts or accessibility.
                self.hidePassword()
                self.message = "無法讀取登入密碼，請確認系統存取授權後重試。"
            }
        }
        if operationID == operation { cancelPendingRead = cancellation }
        else { cancellation?() }
    }

    private func requireAccess() -> Bool {
        guard isUnlocked else { lock(event: "取用被拒絕"); return false }
        return selectedIdentityIsCurrent()
    }

    private func latestHost(_ id: UUID) -> HostProfile? {
        if let currentHost { return currentHost(id) }
        return hosts.first { $0.id == id }
    }

    private func selectedIdentityIsCurrent() -> Bool {
        guard let selectedHost else { return true }
        guard latestHost(selectedHost.id).map(ProtectedCredentialIdentity.init) == ProtectedCredentialIdentity(selectedHost),
              selectedRevision == revision(selectedHost.id) else {
            clipboard.invalidate(hostID: selectedHost.id)
            lock(event: "登入資訊已更新")
            return false
        }
        return true
    }

    private func cancelRead() {
        operationID = nil
        isReading = false
        let cancel = cancelPendingRead
        cancelPendingRead = nil
        cancel?()
    }
    private func clearSelection() {
        cancelRead()
        hidePassword()
        selectedHost = nil
        selectedRevision = nil
        passwordIsMissing = false
        message = nil
    }

    private func clearPresentation() {
        clearSelection()
        searchText = ""
        visibleHosts = []
    }

    deinit { timer?.invalidate() }
}
