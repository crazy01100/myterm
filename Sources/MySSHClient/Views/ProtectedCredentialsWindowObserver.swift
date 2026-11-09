import AppKit
import SwiftUI

/// Observes only the containing window and page region. Never consumes events
/// or records key contents; a hidden credentials page must not affect Terminal.
struct ProtectedCredentialsWindowObserver: NSViewRepresentable {
    let store: ProtectedCredentialsStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(window)
        }
        context.coordinator.view = view
        return view
    }
    func updateNSView(_ nsView: Anchor, context: Context) { }
    static func dismantleNSView(_ nsView: Anchor, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.removeObservers()
        // No ObservableObject callbacks while SwiftUI is dismantling a view.
    }

    final class Anchor: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindowChange?(window) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        private let store: ProtectedCredentialsStore
        weak var view: NSView?
        private weak var window: NSWindow?
        private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
        private var monitor: Any?

        init(store: ProtectedCredentialsStore) { self.store = store }

        func attach(_ window: NSWindow?) {
            removeObservers()
            self.window = window
            store.setBoundary { [weak window] in
                guard let window else { return false }
                return NSApp.isActive && window.isKeyWindow && window.isVisible && !window.isMiniaturized
                    && window.attachedSheet == nil && NSApp.modalWindow == nil
            }
            guard let window else { return }
            for (name, label) in [
                (NSWindow.willCloseNotification, "視窗關閉"),
                (NSWindow.didMiniaturizeNotification, "視窗最小化")
            ] { observe(name, center: .default, object: window, label: label) }
            observe(NSWindow.didResignKeyNotification, center: .default, object: window,
                    label: "視窗焦點交接", focusHandoff: true)
            observe(NSApplication.willResignActiveNotification, center: .default,
                    label: "App 前景交接", focusHandoff: true)
            observe(NSApplication.didHideNotification, center: .default, label: "App 隱藏")
            let workspace = NSWorkspace.shared.notificationCenter
            let activation = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                    object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                        self.store.lifecycleEvent("無法辨識前景交接")
                        return
                    }
                    if activated.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                        self.store.boundaryReady()
                    } else if self.store.isAuthenticating && ProtectedCredentialsFocusPolicy.isSystemAuthenticationAgent(
                        bundleID: activated.bundleIdentifier, executablePath: activated.executableURL?.path) {
                        self.store.focusTemporarilyLost("系統認證面板取得焦點")
                    } else {
                        self.store.lifecycleEvent("已切換至其他 App",
                            clearClipboard: activated.bundleIdentifier == "com.apple.loginwindow")
                    }
                }
            }
            tokens.append((workspace, activation))
            let key = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                             object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let keyWindow = note.object as? NSWindow else { return }
                    if keyWindow === self.window { self.store.boundaryReady() }
                    else { self.store.lifecycleEvent("已切換至其他視窗") }
                }
            }
            tokens.append((.default, key))
            let foreground = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.boundaryReady() }
            }
            tokens.append((.default, foreground))
            for (name, label) in [
                (NSWorkspace.willSleepNotification, "系統即將睡眠"),
                (NSWorkspace.screensDidSleepNotification, "顯示器睡眠"),
                (NSWorkspace.sessionDidResignActiveNotification, "使用者工作階段離開"),
                (NSWorkspace.didWakeNotification, "系統喚醒"),
                (NSWorkspace.screensDidWakeNotification, "顯示器喚醒")
            ] { observe(name, center: workspace, label: label, clearClipboard: true) }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) {
                [weak self] event in
                guard let self, event.window === self.window, self.store.isUnlocked, let view = self.view else { return event }
                if event.type == .keyDown {
                    if !event.isARepeat { self.store.interaction() }
                } else if view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                    self.store.interaction()
                }
                return event
            }
            DispatchQueue.main.async { [weak self] in self?.store.boundaryReady() }
        }

        private func observe(_ name: Notification.Name, center: NotificationCenter, object: AnyObject? = nil,
                             label: String, clearClipboard: Bool = false, focusHandoff: Bool = false) {
            let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                // .main delivery is required for immediate UI invalidation before another action.
                MainActor.assumeIsolated {
                    if focusHandoff { self?.store.focusTemporarilyLost(label) }
                    else { self?.store.lifecycleEvent(label, clearClipboard: clearClipboard) }
                }
            }
            tokens.append((center, token))
        }

        func removeObservers() {
            for (center, token) in tokens { center.removeObserver(token) }
            tokens.removeAll()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            window = nil
        }

        deinit {
            for (center, token) in tokens { center.removeObserver(token) }
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
