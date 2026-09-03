import AppKit
import SwiftUI
import SwiftTerm

enum TerminalCanvasAppearance {
    static let horizontalContentInset: CGFloat = 8
    static let verticalContentInset: CGFloat = 4

    static func backgroundColor(for colorScheme: ColorScheme) -> NSColor {
        if colorScheme == .dark {
            NSColor(srgbRed: 0.045, green: 0.070, blue: 0.115, alpha: 1)
        } else {
            NSColor(srgbRed: 0.955, green: 0.972, blue: 0.985, alpha: 1)
        }
    }
}

struct TerminalContainerView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @Environment(\.colorScheme) private var colorScheme
    let isVisible: Bool
    let isActive: Bool
    let onCloseAfterUserEOF: () -> Void
    let onPlatformDetected: (HostPlatform) -> Void
    let onActivate: () -> Void
    let onRetry: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            isVisible: isVisible,
            onCloseAfterUserEOF: onCloseAfterUserEOF,
            onActivate: onActivate
        )
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LoginAwareTerminalView(frame: .zero)
        context.coordinator.isVisible = isVisible
        context.coordinator.isActive = isActive
        terminal.processDelegate = context.coordinator
        terminal.font = NSFont(name: "SFMono-Regular", size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        terminal.fontSmoothing = true
        terminal.scrollerStyle = .overlay
        terminal.hideScrollIndicator()
        applyTheme(to: terminal)
        context.coordinator.lastAppliedColorScheme = colorScheme
        context.coordinator.installControlDMonitor(for: terminal)
        context.coordinator.installActivationMonitor(for: terminal)
        if session.kind == .ssh {
            terminal.onPlatformDetected = { platform in
                Task { @MainActor in onPlatformDetected(platform) }
            }
            if let host = session.host,
               host.detectedPlatform == nil,
               let username = session.username {
                context.coordinator.startPlatformProbe(
                    host: host,
                    username: username,
                    onDetected: onPlatformDetected
                )
            }
        }
        terminal.onPasswordPromptStateChanged = { [weak session] isAwaitingPassword in
            Task { @MainActor in session?.setPasswordPromptActive(isAwaitingPassword) }
        }
        terminal.onUserInput = { [weak session] in
            Task { @MainActor in session?.setPasswordPromptActive(false) }
        }
        terminal.onActivated = {
            Task { @MainActor in onActivate() }
        }
        terminal.shouldReconnectOnReturn = { [weak session] in
            session?.canReconnectOnReturn == true
        }
        terminal.onReconnectRequested = {
            Task { @MainActor in onRetry() }
        }
        if session.canCapturePasswordForSaving {
            terminal.onLoginPasswordPrompt = { [weak terminal, weak session] in
                Task { @MainActor in
                    guard let session else { return }
                    session.setPasswordPromptActive(true)
                    switch session.nextLoginPasswordPromptAction() {
                    case .useSavedPassword:
                        session.sendSavedPassword(automatic: true)
                    case .captureAttempt:
                        terminal?.beginCapturingLoginPassword()
                        _ = session.prepareForLoginPasswordEntry()
                    case nil:
                        break
                    }
                }
            }
            terminal.onLoginPasswordSubmitted = { [weak session] passwordData in
                Task { @MainActor in session?.receiveSubmittedLoginPassword(passwordData) }
            }
            terminal.onLoginPasswordCaptureCancelled = { [weak session] in
                Task { @MainActor in session?.cancelSubmittedLoginPassword() }
            }
            terminal.onPasswordChangeStarted = { [weak session] in
                Task { @MainActor in session?.passwordChangeDidStart() }
            }
            terminal.onPasswordChangeVerified = { [weak session] passwordData in
                Task { @MainActor in session?.receiveVerifiedChangedPassword(passwordData) }
            }
            terminal.onPasswordChangeRejected = { [weak session] in
                Task { @MainActor in session?.passwordChangeWasRejected() }
            }
        }
        session.attach(terminal: terminal)
        terminal.startProcess(
            executable: session.executable,
            args: session.arguments,
            environment: session.environment,
            execName: session.execName,
            currentDirectory: session.currentDirectory
        )
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.isVisible = isVisible
        context.coordinator.isActive = isActive
        context.coordinator.onActivate = onActivate
        if context.coordinator.lastAppliedColorScheme != colorScheme {
            applyTheme(to: nsView)
            context.coordinator.lastAppliedColorScheme = colorScheme
        }
    }

    private func applyTheme(to terminal: LocalProcessTerminalView) {
        if colorScheme == .dark {
            terminal.nativeForegroundColor = NSColor(srgbRed: 0.88, green: 0.92, blue: 0.97, alpha: 1)
            terminal.caretColor = NSColor(srgbRed: 0.35, green: 0.78, blue: 1.0, alpha: 1)
            terminal.selectedTextBackgroundColor = NSColor(srgbRed: 0.16, green: 0.33, blue: 0.52, alpha: 1)
            terminal.selectedTextForegroundColor = .white
        } else {
            terminal.nativeForegroundColor = NSColor(srgbRed: 0.13, green: 0.18, blue: 0.28, alpha: 1)
            terminal.caretColor = NSColor(srgbRed: 0.15, green: 0.47, blue: 0.93, alpha: 1)
            terminal.selectedTextBackgroundColor = NSColor(srgbRed: 0.72, green: 0.84, blue: 1.0, alpha: 1)
            terminal.selectedTextForegroundColor = NSColor(srgbRed: 0.07, green: 0.15, blue: 0.25, alpha: 1)
        }
        terminal.nativeBackgroundColor = TerminalCanvasAppearance.backgroundColor(for: colorScheme)
        terminal.layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.removeControlDMonitor()
        coordinator.removeActivationMonitor()
        coordinator.cancelPlatformProbe()
        // Do not mutate the observed TerminalSession while SwiftUI is destroying
        // its view graph. Explicit closes already clean up through disconnect(),
        // while natural process exits are handled by processTerminated().
        if nsView.process.running { nsView.process.terminate() }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let session: TerminalSession
        let onCloseAfterUserEOF: () -> Void
        var onActivate: () -> Void
        private var controlDMonitor: Any?
        private var activationMonitor: Any?
        private var platformProbeTask: Task<Void, Never>?
        private var closeAfterEOFRequested = false
        var isVisible: Bool
        var isActive = false
        var lastAppliedColorScheme: ColorScheme?
        @MainActor init(
            session: TerminalSession,
            isVisible: Bool,
            onCloseAfterUserEOF: @escaping () -> Void,
            onActivate: @escaping () -> Void
        ) {
            self.session = session
            self.isVisible = isVisible
            self.onCloseAfterUserEOF = onCloseAfterUserEOF
            self.onActivate = onActivate
        }

        func installActivationMonitor(for terminal: LocalProcessTerminalView) {
            removeActivationMonitor()
            activationMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self, weak terminal] event in
                guard let self, let terminal, event.window === terminal.window else { return event }
                guard self.isVisible else { return event }
                let point = terminal.convert(event.locationInWindow, from: nil)
                guard terminal.bounds.contains(point) else { return event }
                terminal.window?.makeFirstResponder(terminal)
                self.onActivate()
                return event
            }
        }

        func removeActivationMonitor() {
            if let activationMonitor {
                NSEvent.removeMonitor(activationMonitor)
                self.activationMonitor = nil
            }
        }

        func installControlDMonitor(for terminal: LocalProcessTerminalView) {
            removeControlDMonitor()
            controlDMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak terminal] event in
                guard let self, let terminal else { return event }
                guard self.isActive,
                      event.window === terminal.window,
                      event.modifierFlags.contains(.control),
                      !event.modifierFlags.contains(.command),
                      !event.modifierFlags.contains(.option),
                      !event.modifierFlags.contains(.shift),
                      event.keyCode == 2 else { return event }

                if self.session.kind == .serial {
                    self.onCloseAfterUserEOF()
                    return nil
                }
                self.closeAfterEOFRequested = true
                terminal.process.send(data: [0x04][...])
                return nil
            }
        }

        func removeControlDMonitor() {
            if let controlDMonitor {
                NSEvent.removeMonitor(controlDMonitor)
                self.controlDMonitor = nil
            }
        }

        func startPlatformProbe(
            host: HostProfile,
            username: String,
            onDetected: @escaping (HostPlatform) -> Void
        ) {
            cancelPlatformProbe()
            platformProbeTask = Task {
                do {
                    // Allow the interactive connection to finish host-key and
                    // authentication setup before the silent read-only probe.
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let platform = await Task.detached(priority: .utility) {
                    HostPlatformProbe.detect(host: host, username: username)
                }.value
                guard !Task.isCancelled, let platform else { return }
                await MainActor.run { onDetected(platform) }
            }
        }

        func cancelPlatformProbe() {
            platformProbeTask?.cancel()
            platformProbeTask = nil
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) { }
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            Task { @MainActor [weak session] in
                guard let session else { return }
                session.terminalTitle = title.isEmpty ? session.displayName : title
            }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { }
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            cancelPlatformProbe()
            Task { @MainActor [weak session] in
                let shouldClose = self.closeAfterEOFRequested
                session?.processDidTerminate(exitCode: exitCode)
                if shouldClose { self.onCloseAfterUserEOF() }
            }
        }
    }
}

/// Watches only the SSH authentication phase. Saved passwords remain one-shot.
/// When no password exists, repeated login prompts replace the prior captured
/// attempt until OpenSSH independently confirms successful authentication.
final class LoginAwareTerminalView: LocalProcessTerminalView {
    var onLoginPasswordPrompt: (() -> Void)?
    var onLoginPasswordSubmitted: ((Data) -> Void)?
    var onLoginPasswordCaptureCancelled: (() -> Void)?
    var onPasswordChangeStarted: (() -> Void)?
    var onPasswordChangeVerified: ((Data) -> Void)?
    var onPasswordChangeRejected: (() -> Void)?
    var onPlatformDetected: ((HostPlatform) -> Void)?
    var onPasswordPromptStateChanged: ((Bool) -> Void)?
    var onUserInput: (() -> Void)?
    var onActivated: (() -> Void)?
    var shouldReconnectOnReturn: (() -> Bool)?
    var onReconnectRequested: (() -> Void)?
    private var promptDetector = LoginPasswordPromptDetector()
    private var passwordPromptStateDetector = PasswordPromptStateDetector()
    private var platformDetector = HostPlatformDetector()
    private var passwordCapture = LoginPasswordCapture()
    private var passwordChangeCapture = PasswordChangeCapture()
    private var isCoalescingInterruptedOutput = false
    private var interruptedOutputTail: [UInt8] = []
    private var interruptedOutputFlushWorkItem: DispatchWorkItem?
    private var interruptedOutputDeadline: DispatchTime?
    private let interruptedOutputTailLimit = 16 * 1024
    private let interruptedOutputMaximumDelay: UInt64 = 500_000_000
    private var isLoginPasswordPromptMonitoringEnabled = true

    func hideScrollIndicator() {
        subviews
            .compactMap { $0 as? NSScroller }
            .forEach { $0.isHidden = true }
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        onActivated?()
        super.mouseDown(with: event)
    }

    deinit {
        passwordCapture.cancel()
        passwordChangeCapture.cancel()
        for index in interruptedOutputTail.indices { interruptedOutputTail[index] = 0 }
    }

    func beginCapturingLoginPassword() {
        passwordCapture.begin()
    }

    func stopLoginPasswordPromptMonitoring() {
        isLoginPasswordPromptMonitoringEnabled = false
        passwordCapture.cancel()
    }

    func prepareForSSHReconnect() {
        passwordCapture.cancel()
        passwordChangeCapture.cancel()
        promptDetector = LoginPasswordPromptDetector()
        passwordPromptStateDetector = PasswordPromptStateDetector()
        platformDetector = HostPlatformDetector()
        passwordCapture = LoginPasswordCapture()
        passwordChangeCapture = PasswordChangeCapture()
        isLoginPasswordPromptMonitoringEnabled = true
        interruptedOutputFlushWorkItem?.cancel()
        interruptedOutputFlushWorkItem = nil
        interruptedOutputDeadline = nil
        isCoalescingInterruptedOutput = false
        for index in interruptedOutputTail.indices { interruptedOutputTail[index] = 0 }
        interruptedOutputTail.removeAll(keepingCapacity: true)

        // A remote TUI may disappear before it can restore terminal modes.
        // Disable common mouse/paste modes without clearing retained scrollback.
        // DECRST 1049 also restores a saved cursor, so only send it while the
        // alternate buffer is actually active; sending it on the normal buffer
        // can move reconnect output into an old position in the scrollback.
        let resetModes = TerminalReconnectPresentationPolicy.resetModes(
            isAlternateBuffer: terminal.isCurrentBufferAlternate
        )
        super.dataReceived(slice: resetModes[...])
        terminal.softReset()

        // Start the replacement shell after all retained content. Moving the
        // cursor to the last row and writing the reconnect message causes a
        // normal scroll, preserving the previous session above it.
        terminal.buffer.x = 0
        terminal.buffer.y = TerminalReconnectPresentationPolicy.bottomRow(for: terminal.rows)
        scrollTo(row: Int.max, notifyAccessibility: false)
    }

    func displayLocalMessage(_ message: String) {
        let bytes = Array("\r\n\(message)\r\n".utf8)
        super.dataReceived(slice: bytes[...])
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !process.running,
           TerminalReconnectPolicy.isReturnInput(data),
           shouldReconnectOnReturn?() == true {
            onReconnectRequested?()
            return
        }
        let captureResult = passwordCapture.consume(data)
        let passwordChangeResult = onPasswordChangeVerified == nil
            ? PasswordChangeCaptureResult.none
            : passwordChangeCapture.consumeInput(data)
        if data.contains(0x03) {
            beginCoalescingInterruptedOutput()
        }
        if passwordPromptStateDetector.userDidSendInput() != nil {
            onPasswordPromptStateChanged?(false)
        }
        onUserInput?()
        super.send(source: source, data: data)
        switch captureResult {
        case .none:
            break
        case .submitted(let passwordData):
            onLoginPasswordSubmitted?(passwordData)
        case .cancelled:
            onLoginPasswordCaptureCancelled?()
        }
        handlePasswordChangeResult(passwordChangeResult)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if isCoalescingInterruptedOutput {
            retainInterruptedOutputTail(slice)
            if let deadline = interruptedOutputDeadline, DispatchTime.now() >= deadline {
                flushInterruptedOutputTail()
            } else {
                scheduleInterruptedOutputFlush()
            }
            return
        }
        deliverReceivedData(slice)
    }

    private func deliverReceivedData(_ slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        if onPasswordChangeVerified != nil {
            let passwordChangeResult = passwordChangeCapture.consumeOutput(slice)
            if passwordChangeResult == .started {
                // A forced change may begin before the OpenSSH diagnostic
                // monitor observes successful authentication. Do not mistake
                // its "Current password" prompt for another login retry.
                stopLoginPasswordPromptMonitoring()
            }
            handlePasswordChangeResult(passwordChangeResult)
        }
        if let state = passwordPromptStateDetector.consume(slice) {
            onPasswordPromptStateChanged?(state)
        }
        if let platform = platformDetector.consume(slice) {
            let callback = onPlatformDetected
            onPlatformDetected = nil
            callback?(platform)
        }
        if isLoginPasswordPromptMonitoringEnabled,
           onLoginPasswordPrompt != nil,
           promptDetector.consume(slice) {
            promptDetector = LoginPasswordPromptDetector()
            onLoginPasswordPrompt?()
        }
    }

    private func handlePasswordChangeResult(_ result: PasswordChangeCaptureResult) {
        switch result {
        case .none:
            break
        case .started:
            onPasswordChangeStarted?()
        case .verified(var passwordData):
            defer {
                if !passwordData.isEmpty { passwordData.resetBytes(in: passwordData.indices) }
            }
            onPasswordChangeVerified?(passwordData)
        case .rejected:
            onPasswordChangeRejected?()
        }
    }

    private func beginCoalescingInterruptedOutput() {
        interruptedOutputFlushWorkItem?.cancel()
        interruptedOutputTail.removeAll(keepingCapacity: true)
        interruptedOutputDeadline = .now() + .nanoseconds(Int(interruptedOutputMaximumDelay))
        isCoalescingInterruptedOutput = true
        scheduleInterruptedOutputFlush()
    }

    private func retainInterruptedOutputTail(_ slice: ArraySlice<UInt8>) {
        interruptedOutputTail.append(contentsOf: slice)
        if interruptedOutputTail.count > interruptedOutputTailLimit {
            interruptedOutputTail.removeFirst(interruptedOutputTail.count - interruptedOutputTailLimit)
        }
    }

    private func scheduleInterruptedOutputFlush() {
        interruptedOutputFlushWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushInterruptedOutputTail()
        }
        interruptedOutputFlushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: workItem)
    }

    private func flushInterruptedOutputTail() {
        interruptedOutputFlushWorkItem?.cancel()
        interruptedOutputFlushWorkItem = nil
        interruptedOutputDeadline = nil
        isCoalescingInterruptedOutput = false
        let tail = interruptedOutputTail
        interruptedOutputTail.removeAll(keepingCapacity: true)
        guard !tail.isEmpty else { return }
        deliverReceivedData(tail[...])
    }
}
