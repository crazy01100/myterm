import AppKit
import QuartzCore
import SwiftUI
import SwiftTerm

enum TerminalCanvasAppearance {
    static let horizontalContentInset: CGFloat = 8
    static let verticalContentInset: CGFloat = 4

    static func backgroundColor(for colorScheme: ColorScheme) -> NSColor {
        (colorScheme == .dark ? TerminalOutputTheme.dark : .light).background
    }
}

struct TerminalContainerView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(TerminalMessageHighlight.storageKey) private var messageHighlightEnabled = true
    let isVisible: Bool
    let isActive: Bool
    let onCloseAfterUserEOF: () -> Void
    let onPlatformDetected: (HostPlatform) -> Void
    let onActivate: () -> Void
    let onOutputActivity: () -> Void
    let onRetry: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            isVisible: isVisible,
            onCloseAfterUserEOF: onCloseAfterUserEOF,
            onActivate: onActivate,
            onOutputActivity: onOutputActivity
        )
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LoginAwareTerminalView(frame: .zero)
        // Configure cell height before the process starts; changing it on a
        // live, nonzero frame would enter SwiftTerm's font-reset resize path.
        terminal.lineSpacing = TerminalTypography.lineSpacing
        terminal.useSteadyCaret()
        context.coordinator.isVisible = isVisible
        context.coordinator.isActive = isActive
        terminal.processDelegate = context.coordinator
        applyFont(to: terminal)
        terminal.fontSmoothing = true
        terminal.scrollerStyle = .overlay
        terminal.hideScrollIndicator()
        applyTheme(to: terminal)
        context.coordinator.lastAppliedColorScheme = colorScheme
        TerminalMessageHighlight.apply(to: terminal, enabled: messageHighlightEnabled, isDark: colorScheme == .dark)
        context.coordinator.lastMessageHighlightEnabled = messageHighlightEnabled
        context.coordinator.installControlDMonitor(for: terminal)
        context.coordinator.installActivationMonitor(for: terminal)
        context.coordinator.installTextCursorMonitor(for: terminal)
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
        terminal.onOutputActivity = { [weak coordinator = context.coordinator] in
            // SwiftTerm's LocalProcess delivers renderer updates on its main
            // queue. Keep this callback synchronous so a fast producer cannot
            // enqueue one MainActor task per output chunk.
            coordinator?.onOutputActivity()
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
        context.coordinator.onOutputActivity = onOutputActivity
        if nsView.font.pointSize != CGFloat(session.terminalFontSize) {
            applyFont(to: nsView)
        }
        if context.coordinator.lastAppliedColorScheme != colorScheme {
            applyTheme(to: nsView)
            TerminalMessageHighlight.apply(to: nsView, enabled: messageHighlightEnabled, isDark: colorScheme == .dark)
            context.coordinator.lastAppliedColorScheme = colorScheme
        }
        if context.coordinator.lastMessageHighlightEnabled != messageHighlightEnabled {
            TerminalMessageHighlight.apply(to: nsView, enabled: messageHighlightEnabled, isDark: colorScheme == .dark)
            context.coordinator.lastMessageHighlightEnabled = messageHighlightEnabled
        }
    }

    private func applyFont(to terminal: LocalProcessTerminalView) {
        terminal.applyTerminalFontSize(session.terminalFontSize)
    }

    private func applyTheme(to terminal: LocalProcessTerminalView) {
        (colorScheme == .dark ? TerminalOutputTheme.dark : .light).apply(to: terminal)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.removeControlDMonitor()
        coordinator.removeActivationMonitor()
        coordinator.removeTextCursorMonitor()
        coordinator.cancelPlatformProbe()
        // Do not mutate the observed TerminalSession while SwiftUI is destroying
        // its view graph. Explicit closes already clean up through disconnect(),
        // while natural process exits are handled by processTerminated().
        if nsView.process.running { nsView.process.terminate() }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var lastMessageHighlightEnabled: Bool?
        let session: TerminalSession
        let onCloseAfterUserEOF: () -> Void
        var onActivate: () -> Void
        var onOutputActivity: () -> Void
        private var controlDMonitor: Any?
        private var activationMonitor: Any?
        private var textCursorMonitor: Any?
        private var isCursorHiddenForTerminalScroll = false
        private var platformProbeTask: Task<Void, Never>?
        private var closeAfterEOFRequested = false
        var isVisible: Bool
        var isActive = false
        var lastAppliedColorScheme: ColorScheme?
        @MainActor init(
            session: TerminalSession,
            isVisible: Bool,
            onCloseAfterUserEOF: @escaping () -> Void,
            onActivate: @escaping () -> Void,
            onOutputActivity: @escaping () -> Void
        ) {
            self.session = session
            self.isVisible = isVisible
            self.onCloseAfterUserEOF = onCloseAfterUserEOF
            self.onActivate = onActivate
            self.onOutputActivity = onOutputActivity
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

        func installTextCursorMonitor(for terminal: LoginAwareTerminalView) {
            removeTextCursorMonitor()
            textCursorMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .cursorUpdate, .scrollWheel]
            ) { [weak self, weak terminal] event in
                guard let self, let terminal, event.window === terminal.window else { return event }
                guard self.isVisible else { return event }
                let point = terminal.convert(event.locationInWindow, from: nil)
                guard terminal.bounds.contains(point) else { return event }

                if event.type == .scrollWheel {
                    // AppKit can repeatedly restore the arrow while a hosted
                    // terminal processes wheel events. Avoid visible pointer
                    // oscillation by hiding it during scrolling; the system
                    // reveals it on real pointer movement, where this monitor
                    // immediately restores the I-beam.
                    if !self.isCursorHiddenForTerminalScroll {
                        NSCursor.setHiddenUntilMouseMoves(true)
                        self.isCursorHiddenForTerminalScroll = true
                    }
                    // SwiftTerm turns wheel input into Up/Down key presses in an
                    // alternate buffer when the remote app has not enabled mouse
                    // reporting. Its public send path marks every generated arrow
                    // as interactive keyboard input, which forces each Vim reply
                    // to render immediately for 150 ms. Consume only that fallback
                    // case and pace the same arrows at one step per display frame,
                    // while intermediate showcmd/caret frames coalesce.
                    return terminal.consumeAlternateBufferScroll(event) ? nil : event
                }

                if event.type == .cursorUpdate,
                   self.isCursorHiddenForTerminalScroll {
                    // A cursor update can be emitted while a wheel gesture is
                    // still in progress. Keep the pointer hidden until a real
                    // mouse-moved event reveals it instead of re-registering
                    // I-beam and arrow images for every scroll frame.
                    return nil
                }

                if event.type == .mouseMoved {
                    self.isCursorHiddenForTerminalScroll = false
                }

                // Setting the same cursor for every mouse-moved event is not
                // free on macOS: accessibility cursor styling may regenerate
                // and register its image each time. Reassert it only after
                // another view or the system has actually changed the cursor.
                if NSCursor.current != NSCursor.iBeam {
                    NSCursor.iBeam.set()
                }
                // The hosted terminal hierarchy would otherwise process the
                // same cursor-update event afterward and restore the arrow.
                // Mouse movement still passes through; only this semantic
                // cursor update is satisfied here.
                return event.type == .cursorUpdate ? nil : event
            }
        }

        func removeTextCursorMonitor() {
            if let textCursorMonitor {
                NSEvent.removeMonitor(textCursorMonitor)
                self.textCursorMonitor = nil
            }
            isCursorHiddenForTerminalScroll = false
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
    var onOutputActivity: (() -> Void)?
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
    private var pendingMouseWheelInput: [UInt8] = []
    private var pendingMouseWheelFlush: DispatchWorkItem?
    private var alternateBufferScrollAccumulator: CGFloat = 0
    private var pendingAlternateBufferScrollSteps = 0
    private var pendingScrollResponse: [UInt8] = []
    private final class ScrollFrameDisplayLinkTarget: NSObject {
        weak var owner: LoginAwareTerminalView?

        init(owner: LoginAwareTerminalView) {
            self.owner = owner
        }

        @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
            owner?.processScrollFrame(displayLink)
        }
    }

    private lazy var scrollFrameDisplayLinkTarget = ScrollFrameDisplayLinkTarget(owner: self)
    private var scrollFrameDisplayLink: CADisplayLink?
    private var scrollResponseDeadline: DispatchTime?
    private var pendingCaretVisibility: Bool?
    private var pendingCaretVisibilityFlush: DispatchWorkItem?
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

    override func linefeed(source: Terminal) {
        let remoteMouseReportingActive = allowMouseReporting && source.mouseMode != .off
        guard TerminalSelectionInteractionPolicy.shouldClearLocalSelectionOnLinefeed(
            remoteMouseReportingActive: remoteMouseReportingActive
        ) else {
            // Ordinary shell output must not erase a manual selection. When a
            // TUI explicitly owns the mouse, keep SwiftTerm's native behavior
            // so clicks, drags and scrolling remain coherent.
            return
        }
        super.linefeed(source: source)
    }

    deinit {
        pendingMouseWheelFlush?.cancel()
        scrollFrameDisplayLink?.invalidate()
        pendingCaretVisibilityFlush?.cancel()
        passwordCapture.cancel()
        passwordChangeCapture.cancel()
        for index in interruptedOutputTail.indices { interruptedOutputTail[index] = 0 }
    }

    func beginCapturingLoginPassword() {
        passwordCapture.begin()
    }

    func useSteadyCaret() {
        terminal.setCursorStyle(.steadyBlock)
    }

    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        let steadyStyle: CursorStyle
        switch newStyle {
        case .blinkBlock:
            steadyStyle = .steadyBlock
        case .blinkUnderline:
            steadyStyle = .steadyUnderline
        case .blinkBar:
            steadyStyle = .steadyBar
        case .steadyBlock, .steadyUnderline, .steadyBar:
            steadyStyle = newStyle
        }
        super.cursorStyleChanged(source: source, newStyle: steadyStyle)
    }

    override func showCursor(source: Terminal) {
        scheduleCaretVisibility(true, source: source)
    }

    override func hideCursor(source: Terminal) {
        scheduleCaretVisibility(false, source: source)
    }

    private func scheduleCaretVisibility(_ isVisible: Bool, source: Terminal) {
        pendingCaretVisibility = isVisible
        guard pendingCaretVisibilityFlush == nil else { return }
        let workItem = DispatchWorkItem { [weak self, weak source] in
            guard let source else { return }
            self?.applyPendingCaretVisibility(source: source)
        }
        pendingCaretVisibilityFlush = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func applyPendingCaretVisibility(source: Terminal) {
        guard let isVisible = pendingCaretVisibility else { return }
        pendingCaretVisibility = nil
        pendingCaretVisibilityFlush = nil
        if isVisible {
            super.showCursor(source: source)
        } else {
            super.hideCursor(source: source)
        }
    }

    func stopLoginPasswordPromptMonitoring() {
        isLoginPasswordPromptMonitoringEnabled = false
        passwordCapture.cancel()
    }

    func prepareForSSHReconnect() {
        flushScrollResponse()
        scrollResponseDeadline = nil
        pendingMouseWheelFlush?.cancel()
        pendingMouseWheelFlush = nil
        pendingMouseWheelInput.removeAll(keepingCapacity: true)
        alternateBufferScrollAccumulator = 0
        pendingAlternateBufferScrollSteps = 0
        updateScrollFrameDisplayLinkState()
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
        let inputBytes = Array(data)
        if TerminalMouseWheelReportPolicy.isMouseWheelReport(inputBytes) {
            enqueueMouseWheelInput(inputBytes)
        } else {
            flushMouseWheelInput()
            super.send(source: source, data: data)
        }
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

    private func enqueueMouseWheelInput(_ bytes: [UInt8]) {
        pendingMouseWheelInput.append(contentsOf: bytes)
        guard pendingMouseWheelFlush == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushMouseWheelInput()
        }
        pendingMouseWheelFlush = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TerminalMouseWheelReportPolicy.coalescingDelay,
            execute: workItem
        )
    }

    func consumeAlternateBufferScroll(_ event: NSEvent) -> Bool {
        guard event.scrollingDeltaY != 0,
              terminal.isCurrentBufferAlternate,
              !(allowMouseReporting && terminal.mouseMode != .off) else {
            return false
        }

        let rowCount = max(1, terminal.rows)
        let estimatedCellHeight = max(1, bounds.height / CGFloat(rowCount))
        let lines: Int
        if event.hasPreciseScrollingDeltas {
            alternateBufferScrollAccumulator += event.scrollingDeltaY
            lines = Int(alternateBufferScrollAccumulator / estimatedCellHeight)
            alternateBufferScrollAccumulator -= CGFloat(lines) * estimatedCellHeight
        } else {
            alternateBufferScrollAccumulator = 0
            let rounded = Int(event.scrollingDeltaY.rounded())
            lines = rounded != 0 ? rounded : (event.scrollingDeltaY > 0 ? 1 : -1)
        }

        guard lines != 0 else { return true }
        pendingAlternateBufferScrollSteps = TerminalMouseWheelReportPolicy.accumulatePacedScrollSteps(
            current: pendingAlternateBufferScrollSteps,
            adding: lines
        )
        activateScrollFrameDisplayLink()
        return true
    }

    private func beginCoalescingScrollResponse() {
        scrollResponseDeadline = .now() + TerminalMouseWheelReportPolicy.responseCoalescingWindow
    }

    private func shouldCoalesceScrollResponse() -> Bool {
        guard let scrollResponseDeadline else { return false }
        return DispatchTime.now() < scrollResponseDeadline
    }

    private func enqueueScrollResponse(_ slice: ArraySlice<UInt8>) {
        pendingScrollResponse.append(contentsOf: slice)
        if pendingScrollResponse.count >= TerminalMouseWheelReportPolicy.responseBufferLimit {
            flushScrollResponse()
            return
        }
        activateScrollFrameDisplayLink()
    }

    private func activateScrollFrameDisplayLink() {
        if scrollFrameDisplayLink == nil {
            let displayLink = displayLink(
                target: scrollFrameDisplayLinkTarget,
                selector: #selector(ScrollFrameDisplayLinkTarget.displayLinkDidFire(_:))
            )
            displayLink.isPaused = true
            displayLink.add(to: .main, forMode: .common)
            scrollFrameDisplayLink = displayLink
        }
        scrollFrameDisplayLink?.isPaused = false
    }

    fileprivate func processScrollFrame(_ displayLink: CADisplayLink) {
        deliverPendingScrollResponse()

        let paced = TerminalMouseWheelReportPolicy.consumePacedScrollStep(
            pendingAlternateBufferScrollSteps
        )
        pendingAlternateBufferScrollSteps = paced.remaining
        if paced.step != 0 {
            beginCoalescingScrollResponse()
            let sequence = TerminalMouseWheelReportPolicy.alternateBufferArrowSequence(
                scrollingUp: paced.step > 0,
                applicationCursor: terminal.applicationCursor
            )
            process.send(data: sequence[...])
        }

        updateScrollFrameDisplayLinkState()
    }

    private func flushScrollResponse() {
        deliverPendingScrollResponse()
        updateScrollFrameDisplayLinkState()
    }

    private func deliverPendingScrollResponse() {
        guard !pendingScrollResponse.isEmpty else { return }
        let bytes = pendingScrollResponse
        pendingScrollResponse.removeAll(keepingCapacity: true)
        deliverReceivedData(bytes[...])
    }

    private func updateScrollFrameDisplayLinkState() {
        scrollFrameDisplayLink?.isPaused = pendingAlternateBufferScrollSteps == 0 &&
            pendingScrollResponse.isEmpty
    }

    private func flushMouseWheelInput() {
        pendingMouseWheelFlush?.cancel()
        pendingMouseWheelFlush = nil
        guard !pendingMouseWheelInput.isEmpty else { return }
        let bytes = pendingMouseWheelInput
        pendingMouseWheelInput.removeAll(keepingCapacity: true)
        process.send(data: bytes[...])
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
        if shouldCoalesceScrollResponse() {
            enqueueScrollResponse(slice)
            return
        }
        flushScrollResponse()
        scrollResponseDeadline = nil
        deliverReceivedData(slice)
    }

    private func deliverReceivedData(_ slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        if !slice.isEmpty {
            onOutputActivity?()
        }
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
