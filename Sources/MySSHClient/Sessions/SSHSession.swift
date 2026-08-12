import AppKit
import Foundation
import SwiftTerm

enum SessionState: Equatable {
    case connecting
    case connected
    case disconnected(Int32?)
    case failed(String)

    var label: String {
        switch self {
        case .connecting: "連線中"
        case .connected: "已連線"
        case .disconnected(let code): code.map { "已中斷（\($0)）" } ?? "已中斷"
        case .failed(let message): message
        }
    }
}

enum TerminalSessionKind: Equatable {
    case ssh
    case local
    case serial
}

enum PasswordSaveOfferKind: Equatable {
    case login
    case replacementLogin
    case changedPassword
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let kind: TerminalSessionKind
    let host: HostProfile?
    let username: String?
    let serialConfiguration: SerialConfiguration?
    let executable: String
    let arguments: [String]
    let environment: [String]
    let execName: String
    let currentDirectory: String?
    let connectionLogURL: URL?
    @Published var state: SessionState = .connecting
    @Published var terminalTitle: String
    @Published var notice: String?
    @Published private(set) var connectionPhase: SSHConnectionPhase = .preparing
    @Published private(set) var connectionEvents: [SSHConnectionDiagnosticEvent] = [
        SSHConnectionDiagnosticEvent(phase: .preparing, message: "正在準備 SSH 連線設定。")
    ]
    @Published private(set) var connectionTechnicalLines: [String] = []
    @Published private(set) var connectionFailure: SSHConnectionFailureKind?
    @Published private(set) var hasSavedPassword = false
    @Published private(set) var isPasswordPromptActive = false
    @Published private(set) var passwordSaveOfferKind: PasswordSaveOfferKind?
    weak var terminalView: LocalProcessTerminalView?
    private var pendingPasswordData: Data?
    private var loginPasswordPromptPolicy = LoginPasswordPromptPolicy()
    private var connectionLogOffset = 0
    private var authenticationLogDetector = SSHAuthenticationLogDetector()
    private var connectionLogParser = SSHConnectionLogParser()
    private var connectionMonitorTask: Task<Void, Never>?

    var displayName: String {
        switch kind {
        case .ssh: host?.displayName ?? "SSH"
        case .local: "本地 Terminal"
        case .serial: "Serial"
        }
    }

    var detailDescription: String {
        switch kind {
        case .ssh:
            guard let host, let username else { return "SSH" }
            return "\(username)@\(host.hostname):\(host.port)"
        case .local:
            return "本機 · zsh"
        case .serial:
            guard let serialConfiguration else { return "Serial" }
            return "\(serialConfiguration.devicePath) · \(serialConfiguration.baudRate) bps"
        }
    }

    var canBindPasswordToProfile: Bool {
        guard kind == .ssh, let host, let username else { return false }
        return host.authenticationMethod == .password && !host.username.isEmpty && username == host.username
    }

    var canUseSavedPassword: Bool {
        canBindPasswordToProfile && hasSavedPassword
    }

    var canCapturePasswordForSaving: Bool {
        canBindPasswordToProfile && connectionLogURL != nil
    }

    var isOfferingToSavePassword: Bool { passwordSaveOfferKind != nil }

    var canSafelyUseSavedPassword: Bool {
        canUseSavedPassword && isPasswordPromptActive && terminalView != nil
    }

    var shouldPresentConnectionExperience: Bool {
        guard kind == .ssh else { return false }
        return switch state {
        case .connecting, .failed: true
        case .connected, .disconnected: false
        }
    }

    var connectionFailureSuggestion: String? {
        connectionFailure?.recoverySuggestion
    }

    var displayedConnectionTechnicalLines: [String] {
        var lines = connectionTechnicalLines
        for technicalLine in connectionEvents.compactMap(\.technicalLine)
        where !lines.contains(technicalLine) {
            lines.append(technicalLine)
        }
        return SSHConnectionLogParser.userFacingTechnicalLines(from: lines)
    }

    var sanitizedConnectionReport: String {
        var lines = [
            "MyTerm SSH 連線診斷",
            "主機：\(displayName)",
            "端點：\(detailDescription)"
        ]
        lines.append(contentsOf: connectionEvents.map { "[\($0.phase.title)] \($0.message)" })
        if let connectionFailure {
            lines.append("建議：\(connectionFailure.recoverySuggestion)")
        }
        lines.append("")
        lines.append("OpenSSH 原始記錄（已排除詳細除錯資訊，並遮蔽本機路徑與機密資訊）：")
        if displayedConnectionTechnicalLines.isEmpty {
            lines.append("（本次未取得可安全顯示的 OpenSSH 原始記錄。）")
        } else {
            lines.append(contentsOf: displayedConnectionTechnicalLines)
        }
        return lines.joined(separator: "\n")
    }

    func copySanitizedConnectionReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sanitizedConnectionReport, forType: .string)
        notice = "已複製隱私處理後的連線記錄。"
    }

    init(host: HostProfile, username: String) throws {
        let username = try HostProfile.validatedUsername(username)
        let canBindPassword = host.authenticationMethod == .password
            && !host.username.isEmpty
            && username == host.username
        let hasSavedPassword = canBindPassword && KeychainStore.containsPassword(for: host.id)
        let connectionLogURL = try AppPaths.createSSHConnectionLog()
        let arguments: [String]
        do {
            arguments = try SSHArgumentBuilder.arguments(
                for: host,
                usernameOverride: username,
                connectionLogURL: connectionLogURL
            )
        } catch {
            AppPaths.removeSSHConnectionLog(connectionLogURL)
            throw error
        }
        kind = .ssh
        self.host = host
        self.username = username
        serialConfiguration = nil
        executable = "/usr/bin/ssh"
        self.arguments = arguments
        environment = SSHEnvironmentBuilder.environment()
        execName = "ssh"
        currentDirectory = nil
        self.connectionLogURL = connectionLogURL
        self.hasSavedPassword = hasSavedPassword
        terminalTitle = host.displayName
    }

    init(localShell: Void = ()) {
        kind = .local
        host = nil
        username = nil
        serialConfiguration = nil
        executable = "/bin/zsh"
        arguments = ["-l"]
        environment = LocalTerminalEnvironmentBuilder.environment()
        execName = "zsh"
        currentDirectory = LocalTerminalEnvironmentBuilder.currentDirectory()
        connectionLogURL = nil
        terminalTitle = "本地 Terminal"
    }

    init(serial configuration: SerialConfiguration) throws {
        let configuration = try configuration.validated()
        try configuration.prepareDevice()
        kind = .serial
        host = nil
        username = nil
        serialConfiguration = configuration
        executable = "/usr/bin/screen"
        arguments = ["-U", configuration.devicePath, configuration.screenMode]
        environment = LocalTerminalEnvironmentBuilder.environment()
        execName = "screen"
        currentDirectory = nil
        connectionLogURL = nil
        terminalTitle = "Serial"
    }

    func attach(terminal: LocalProcessTerminalView) {
        terminalView = terminal
        if kind == .ssh {
            state = .connecting
            startConnectionMonitor()
        } else {
            state = .connected
        }
    }

    func sendSavedPassword(automatic: Bool = false) {
        guard canUseSavedPassword, let host else {
            notice = "本次帳號沒有綁定可自動使用的密碼。"
            return
        }
        guard isPasswordPromptActive else {
            notice = "未偵測到密碼提示；為保護密碼，MyTerm 已阻止填入。"
            return
        }
        guard let terminalView else {
            notice = "目前沒有可輸入的終端工作階段。"
            return
        }
        do {
            guard var secret = try KeychainStore.passwordData(for: host.id) else {
                notice = "這個主機尚未儲存密碼。"
                return
            }
            var secretBytes = Array(secret)
            secret.resetBytes(in: secret.startIndex..<secret.endIndex)
            secretBytes.append(0x0A)
            isPasswordPromptActive = false
            terminalView.process.send(data: secretBytes[...])
            for index in secretBytes.indices { secretBytes[index] = 0 }
            notice = automatic ? "已使用儲存的密碼登入。" : "密碼已直接送至目前工作階段。"
        } catch {
            notice = error.localizedDescription
        }
    }

    func setPasswordPromptActive(_ isActive: Bool) {
        isPasswordPromptActive = isActive
    }

    func nextLoginPasswordPromptAction() -> LoginPasswordPromptAction? {
        guard canCapturePasswordForSaving else { return nil }
        startConnectionMonitor()
        return loginPasswordPromptPolicy.nextAction(hasSavedPassword: hasSavedPassword)
    }

    func copyTerminalSelection() {
        guard let terminalView else { return }
        terminalView.copy(self)
    }

    func pasteClipboardToTerminal() {
        guard let terminalView else { return }
        terminalView.paste(self)
    }

    func selectAllTerminalContent() {
        guard let terminalView else { return }
        terminalView.selectAll(self)
    }

    func showTerminalFind() {
        guard let terminalView else { return }
        let menuItem = NSMenuItem()
        menuItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        terminalView.performFindPanelAction(menuItem)
    }

    /// Called for each SSH login password prompt while a profile does not yet
    /// have a saved password. A repeated prompt proves the previous attempt
    /// failed, so that attempt is cleared before capturing the next one.
    func prepareForLoginPasswordEntry() -> Bool {
        guard canCapturePasswordForSaving else { return false }
        clearPendingPassword()
        passwordSaveOfferKind = nil
        return true
    }

    func receiveSubmittedLoginPassword(_ submittedData: Data) {
        var submittedData = submittedData
        defer {
            if !submittedData.isEmpty {
                submittedData.resetBytes(in: submittedData.startIndex..<submittedData.endIndex)
            }
        }
        guard canCapturePasswordForSaving, !submittedData.isEmpty else { return }
        clearPendingPassword()
        pendingPasswordData = submittedData
        startConnectionMonitor()
    }

    func cancelSubmittedLoginPassword() {
        clearPendingPassword()
        passwordSaveOfferKind = nil
    }

    func passwordChangeDidStart() {
        // An old login password must never remain eligible for saving once the
        // server has entered a forced password-change sequence.
        clearPendingPassword()
        passwordSaveOfferKind = nil
    }

    func receiveVerifiedChangedPassword(_ verifiedData: Data) {
        var verifiedData = verifiedData
        defer {
            if !verifiedData.isEmpty {
                verifiedData.resetBytes(in: verifiedData.indices)
            }
        }
        guard canBindPasswordToProfile, !verifiedData.isEmpty else { return }
        clearPendingPassword()
        pendingPasswordData = verifiedData
        passwordSaveOfferKind = .changedPassword
        notice = "伺服器已確認新密碼生效。"
    }

    func passwordChangeWasRejected() {
        guard passwordSaveOfferKind != .changedPassword else { return }
        notice = "密碼變更尚未成功，MyTerm 沒有更新儲存的密碼。"
    }

    func saveVerifiedPassword() {
        guard let offerKind = passwordSaveOfferKind,
              let host,
              var passwordData = pendingPasswordData else { return }
        defer {
            if !passwordData.isEmpty {
                passwordData.resetBytes(in: passwordData.startIndex..<passwordData.endIndex)
            }
            clearPendingPassword()
            passwordSaveOfferKind = nil
        }
        do {
            try KeychainStore.save(passwordData: passwordData, for: host.id)
            hasSavedPassword = true
            notice = offerKind == .login
                ? "密碼已安全儲存至這台 Mac 的加密保管庫。"
                : "新的密碼已安全更新至這台 Mac 的加密保管庫。"
        } catch {
            notice = error.localizedDescription
        }
    }

    func declineVerifiedPassword() {
        let offerKind = passwordSaveOfferKind
        clearPendingPassword()
        passwordSaveOfferKind = nil
        notice = offerKind == .login
            ? "本次登入密碼未儲存。"
            : "新密碼未寫入 MyTerm，本機仍保留原本的儲存密碼。"
    }

    func authenticationDidEnd(preserveVerifiedPasswordOffer: Bool = true) {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        if !preserveVerifiedPasswordOffer || passwordSaveOfferKind == nil {
            clearPendingPassword()
            passwordSaveOfferKind = nil
        }
        isPasswordPromptActive = false
        AppPaths.removeSSHConnectionLog(connectionLogURL)
    }

    private func startConnectionMonitor() {
        guard connectionMonitorTask == nil, connectionLogURL != nil else { return }
        connectionMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.inspectConnectionLog()
                do {
                    try await Task.sleep(nanoseconds: 150_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func inspectConnectionLog() {
        guard let connectionLogURL,
              let data = try? Data(contentsOf: connectionLogURL) else { return }
        if data.count < connectionLogOffset {
            connectionLogOffset = 0
            authenticationLogDetector = SSHAuthenticationLogDetector()
            connectionLogParser = SSHConnectionLogParser()
        }
        guard data.count > connectionLogOffset else { return }
        let newBytes = Array(data[connectionLogOffset...])
        connectionLogOffset = data.count
        applyConnectionUpdate(connectionLogParser.consume(newBytes[...]))
        guard let result = authenticationLogDetector.consume(newBytes[...]) else { return }

        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        (terminalView as? LoginAwareTerminalView)?.stopLoginPasswordPromptMonitoring()
        AppPaths.removeSSHConnectionLog(connectionLogURL)

        state = .connected
        connectionPhase = .connected

        switch result {
        case .password:
            if pendingPasswordData?.isEmpty == false {
                passwordSaveOfferKind = hasSavedPassword ? .replacementLogin : .login
                notice = hasSavedPassword
                    ? "新的登入密碼已由 OpenSSH 驗證成功。"
                    : "登入密碼已由 OpenSSH 驗證成功。"
            } else {
                clearPendingPassword()
            }
        case .other(let method):
            clearPendingPassword()
            if method == "keyboard-interactive" {
                notice = "伺服器使用 keyboard-interactive 驗證；為避免誤存一次性密碼，本次不提供儲存。"
            }
        }
        clearConnectionDiagnosticsAfterSuccess()
    }

    private func clearConnectionDiagnosticsAfterSuccess() {
        connectionEvents.removeAll(keepingCapacity: false)
        connectionTechnicalLines.removeAll(keepingCapacity: false)
        connectionFailure = nil
        connectionLogOffset = 0
        authenticationLogDetector = SSHAuthenticationLogDetector()
        connectionLogParser = SSHConnectionLogParser()
    }

    private func applyConnectionUpdate(_ update: SSHConnectionLogUpdate) {
        if !update.events.isEmpty {
            for event in update.events where !connectionEvents.contains(event) {
                connectionEvents.append(event)
                if let technicalLine = event.technicalLine,
                   !connectionTechnicalLines.contains(technicalLine) {
                    connectionTechnicalLines.append(technicalLine)
                }
            }
            if connectionEvents.count > 200 {
                connectionEvents.removeFirst(connectionEvents.count - 200)
            }
            if let phase = update.events.last?.phase {
                connectionPhase = phase
            }
            trimConnectionTechnicalLines()
        }
        if !update.technicalLines.isEmpty {
            connectionTechnicalLines.append(contentsOf: update.technicalLines)
            trimConnectionTechnicalLines()
        }
        if let failure = update.failure {
            connectionFailure = failure
            connectionPhase = .failed
            state = .failed(failure.title)
        }
    }

    private func trimConnectionTechnicalLines() {
        let maximumLines = 200
        let maximumBytes = 65_536
        if connectionTechnicalLines.count > maximumLines {
            connectionTechnicalLines.removeFirst(connectionTechnicalLines.count - maximumLines)
        }
        var byteCount = connectionTechnicalLines.reduce(0) { $0 + $1.utf8.count + 1 }
        while connectionTechnicalLines.count > 1, byteCount > maximumBytes {
            byteCount -= connectionTechnicalLines.removeFirst().utf8.count + 1
        }
    }

    private func finalizeConnectionTechnicalTranscript() {
        guard let connectionLogURL,
              let data = try? Data(contentsOf: connectionLogURL) else { return }
        let transcript = SSHConnectionLogParser.technicalTranscript(from: data)
        guard !transcript.isEmpty else { return }
        connectionTechnicalLines = transcript
        trimConnectionTechnicalLines()
    }

    func processDidTerminate(exitCode: Int32?) {
        guard kind == .ssh else {
            state = .disconnected(exitCode)
            authenticationDidEnd()
            terminalView = nil
            return
        }

        inspectConnectionLog()
        applyConnectionUpdate(connectionLogParser.finish())
        finalizeConnectionTechnicalTranscript()
        if state == .connected {
            state = .disconnected(exitCode)
        } else {
            let failure = connectionFailure ?? .unknown
            connectionFailure = failure
            connectionPhase = .failed
            state = .failed(failure.title)
            let event = SSHConnectionDiagnosticEvent(phase: .failed, message: failure.title)
            if !connectionEvents.contains(where: {
                $0.phase == event.phase && $0.message == event.message
            }) {
                connectionEvents.append(event)
            }
        }
        authenticationDidEnd()
        terminalView = nil
    }

    private func clearPendingPassword() {
        guard var pendingPasswordData else { return }
        if !pendingPasswordData.isEmpty {
            pendingPasswordData.resetBytes(in: pendingPasswordData.startIndex..<pendingPasswordData.endIndex)
        }
        self.pendingPasswordData = nil
    }

    func disconnect() {
        isPasswordPromptActive = false
        authenticationDidEnd(preserveVerifiedPasswordOffer: false)
        terminalView?.process.terminate()
        terminalView = nil
    }

    deinit {
        connectionMonitorTask?.cancel()
        AppPaths.removeSSHConnectionLog(connectionLogURL)
    }
}

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published private var workspaceState = TerminalWorkspaceCollection()
    @Published var lastError: String?

    var workspaces: [TerminalWorkspace] {
        workspaceState.workspaces
    }

    var selectedWorkspaceID: TerminalWorkspace.ID? {
        get { workspaceState.selectedWorkspaceID }
        set { _ = workspaceState.selectWorkspace(id: newValue) }
    }

    var selectedSessionID: TerminalSession.ID? {
        get { workspaceState.selectedSessionID }
        set {
            if let newValue {
                _ = workspaceState.activate(sessionID: newValue)
            } else {
                workspaceState.showLibrary()
            }
        }
    }

    var selectedWorkspace: TerminalWorkspace? {
        workspaceState.selectedWorkspace
    }

    var selectedSession: TerminalSession? {
        session(id: selectedSessionID)
    }

    func session(id: TerminalSession.ID?) -> TerminalSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func workspace(id: TerminalWorkspace.ID?) -> TerminalWorkspace? {
        workspaceState.workspace(id: id)
    }

    func sessions(in workspace: TerminalWorkspace) -> [TerminalSession] {
        workspace.sessionIDs.compactMap { session(id: $0) }
    }

    func workspace(containing sessionID: TerminalSession.ID) -> TerminalWorkspace? {
        workspaceState.workspace(containing: sessionID)
    }

    func preferredMergeTargetID(for workspaceID: TerminalWorkspace.ID) -> TerminalWorkspace.ID? {
        workspaceState.preferredMergeTargetID(for: workspaceID)
    }

    func showHostLibrary() {
        workspaceState.showLibrary()
    }

    @discardableResult
    func createSSHSession(to host: HostProfile, username: String) throws -> TerminalSession.ID {
        let session = try TerminalSession(host: host, username: username)
        sessions.append(session)
        workspaceState.add(sessionID: session.id)
        return session.id
    }

    @discardableResult
    func createLocalSession() -> TerminalSession.ID {
        let session = TerminalSession()
        sessions.append(session)
        workspaceState.add(sessionID: session.id)
        return session.id
    }

    @discardableResult
    func createSerialSession(configuration: SerialConfiguration) throws -> TerminalSession.ID {
        let session = try TerminalSession(serial: configuration)
        sessions.append(session)
        workspaceState.add(sessionID: session.id)
        return session.id
    }

    @discardableResult
    func retry(_ session: TerminalSession) -> Bool {
        guard session.kind == .ssh,
              let host = session.host,
              let username = session.username,
              let sessionIndex = sessions.firstIndex(where: { $0.id == session.id }) else {
            lastError = "找不到可以重新連線的 SSH 工作階段。"
            return false
        }
        do {
            let replacement = try TerminalSession(host: host, username: username)
            guard workspaceState.replace(sessionID: session.id, with: replacement.id) else {
                replacement.disconnect()
                lastError = "無法在目前工作區重新建立 SSH 連線。"
                return false
            }
            session.disconnect()
            sessions[sessionIndex] = replacement
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func close(_ session: TerminalSession) {
        session.disconnect()
        sessions.removeAll { $0.id == session.id }
        _ = workspaceState.close(sessionID: session.id)
    }

    @discardableResult
    func closeActiveSession(in workspaceID: TerminalWorkspace.ID) -> Bool {
        guard let workspace = workspace(id: workspaceID),
              let session = session(id: workspace.activeSessionID) else { return false }
        close(session)
        return true
    }

    func closeSelectedSession() -> Bool {
        guard let selectedSession else { return false }
        close(selectedSession)
        return true
    }

    func selectSession(at index: Int) -> Bool {
        workspaceState.selectWorkspace(at: index)
    }

    func selectAdjacentSession(offset: Int) -> Bool {
        workspaceState.selectAdjacentWorkspace(offset: offset)
    }

    @discardableResult
    func selectWorkspace(_ workspaceID: TerminalWorkspace.ID) -> Bool {
        workspaceState.selectWorkspace(id: workspaceID)
    }

    @discardableResult
    func activate(sessionID: TerminalSession.ID) -> Bool {
        workspaceState.activate(sessionID: sessionID)
    }

    @discardableResult
    func moveWorkspace(_ workspaceID: TerminalWorkspace.ID, toInsertionIndex index: Int) -> Bool {
        workspaceState.moveWorkspace(id: workspaceID, toInsertionIndex: index)
    }

    @discardableResult
    func mergeWorkspaces(
        sourceWorkspaceID: TerminalWorkspace.ID,
        targetWorkspaceID: TerminalWorkspace.ID,
        position: TerminalWorkspaceDropPosition
    ) -> Bool {
        do {
            try workspaceState.merge(
                sourceWorkspaceID: sourceWorkspaceID,
                targetWorkspaceID: targetWorkspaceID,
                position: position
            )
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func detachSession(_ sessionID: TerminalSession.ID, toInsertionIndex index: Int) -> Bool {
        do {
            try workspaceState.detach(sessionID: sessionID, toInsertionIndex: index)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func setSplitAxis(_ splitAxis: TerminalWorkspaceSplitAxis, for workspaceID: TerminalWorkspace.ID) -> Bool {
        workspaceState.setSplitAxis(splitAxis, for: workspaceID)
    }

    @discardableResult
    func toggleSplitAxis(for workspaceID: TerminalWorkspace.ID) -> Bool {
        workspaceState.toggleSplitAxis(for: workspaceID)
    }

    @discardableResult
    func setSplitRatio(_ ratio: Double, for workspaceID: TerminalWorkspace.ID) -> Bool {
        workspaceState.setSplitRatio(ratio, for: workspaceID)
    }

    @discardableResult
    func focusOtherPane() -> Bool {
        workspaceState.focusOtherPane()
    }
}
