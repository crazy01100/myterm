import AppKit
import Combine
import SwiftUI

extension NSWindow {
    var hasQuickActionPanel: Bool {
        childWindows?.contains { $0 is QuickActionWindow } == true
    }
}

private final class QuickActionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A child window isolates the search field from the terminal's responder chain
/// without replacing, resizing, or hiding any existing terminal NSView.
final class QuickActionPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var results: [QuickActionItem] = []
    @Published private(set) var selectedID: QuickActionDestination?
    @Published private(set) var scrollSelectionRevision = 0
    @Published private(set) var shortcutLabel = ""
    @Published private(set) var inputHint: String?
    private var query = ""
    private var items: [QuickActionItem] = []
    private var panel: QuickActionWindow?
    private weak var originalResponder: NSResponder?
    weak var hostWindow: NSWindow?
    weak var searchField: NSTextField?
    var source: () -> [QuickActionItem] = { [] }
    var perform: (QuickActionDestination) -> Void = { _ in }
    var shortcuts: AppShortcutStore?
    var canOpen: () -> Bool = { true }
    private var monitor: Any?
    private var notifications: [NSObjectProtocol] = []
    private var subscriptions: [AnyCancellable] = []
    private var observedSessionIDs: [UUID] = []
    private var lastPointerLocation = NSPoint.zero

    var isPresented: Bool { panel != nil }

    func dispose() {
        close(restoreFocus: false)
        subscriptions.removeAll()
        source = { [] }
        perform = { _ in }
        canOpen = { true }
    }

    @MainActor
    func observe(hosts: HostStore, sessions: SessionManager) {
        let ids = sessions.sessions.map(\.id)
        guard subscriptions.isEmpty || observedSessionIDs != ids else { return }
        observedSessionIDs = ids
        subscriptions = ([hosts.objectWillChange.eraseToAnyPublisher(), sessions.objectWillChange.eraseToAnyPublisher()]
            + sessions.sessions.map { $0.objectWillChange.eraseToAnyPublisher() }).map { publisher in
            publisher.sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        }
    }

    func refresh() {
        guard isPresented else { return }
        if hostWindow?.attachedSheet != nil || NSApp.modalWindow != nil { close(); return }
        items = source()
        updateResults(selectFirst: false)
    }

    func toggle() {
        if isPresented { close(); return }
        guard let hostWindow, hostWindow === NSApp.keyWindow,
              hostWindow.attachedSheet == nil, NSApp.modalWindow == nil, canOpen(),
              !Self.isComposing(in: hostWindow) else { return }
        originalResponder = hostWindow.firstResponder
        lastPointerLocation = NSEvent.mouseLocation
        query = ""
        items = source()
        updateResults(selectFirst: true)
        shortcutLabel = shortcuts?.shortcut(for: .openQuickActions)?.displayText ?? ""
        let window = QuickActionWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "快速操作"
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.acceptsMouseMovedEvents = true
        window.isMovable = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self
        window.appearance = hostWindow.effectiveAppearance
        window.contentView = NSHostingView(rootView: QuickActionPanelView(controller: self))
        panel = window
        position()
        hostWindow.addChildWindow(window, ordered: .above)
        installEvents()
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        if let searchField { window.makeFirstResponder(searchField) }
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            panel.makeFirstResponder(self.searchField)
        }
    }

    func close(restoreFocus: Bool = true) {
        guard let panel else { return }
        self.panel = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        hostWindow?.removeChildWindow(panel)
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
        query = ""
        inputHint = nil
        items = []
        results = []
        selectedID = nil
        searchField = nil
        if restoreFocus, NSApp.isActive, let hostWindow, hostWindow.isVisible {
            hostWindow.makeKey()
            if let view = originalResponder as? NSView, view.window === hostWindow {
                hostWindow.makeFirstResponder(view)
            } else if let editor = originalResponder as? NSTextView,
                      editor.isFieldEditor, editor.window === hostWindow {
                hostWindow.makeFirstResponder(editor)
            } else {
                hostWindow.makeFirstResponder(nil)
            }
        }
        originalResponder = nil
    }

    func search(_ text: String) {
        lastPointerLocation = NSEvent.mouseLocation
        query = text
        items = source()
        updateResults(selectFirst: true)
        scrollSelectionRevision &+= 1
    }

    private func updateResults(selectFirst: Bool) {
        inputHint = (query.contains("@") || query.hasPrefix("ssh ")) && QuickSSHRequest.parse(query) == nil
            ? "請輸入 帳號@主機，可加 :連接埠；IPv6 請使用方括號。" : nil
        let updated = QuickActionSearch.results(items, query: query)
        if updated != results { results = updated }
        if selectFirst { selectedID = updated.first?.id }
        else if let selectedID, !updated.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }

    func move(_ offset: Int) {
        lastPointerLocation = NSEvent.mouseLocation
        guard !results.isEmpty else { return }
        let current = selectedID.flatMap { id in results.firstIndex { $0.id == id } }
        let index = current.map { ($0 + offset + results.count) % results.count } ?? (offset > 0 ? 0 : results.count - 1)
        selectedID = results[index].id
        scrollSelectionRevision &+= 1
    }

    func hover(_ id: QuickActionDestination) {
        let location = NSEvent.mouseLocation
        // Layout/scrolling can re-enter a row under a stationary pointer.
        // Only actual pointer movement takes selection back from the keyboard.
        guard location != lastPointerLocation else { return }
        lastPointerLocation = location
        guard results.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func execute(_ id: QuickActionDestination?) {
        guard let id else { return }
        // Re-read IDs, not an array index captured before a sync/close event.
        guard QuickActionSearch.results(source(), query: query).contains(where: { $0.id == id }) else {
            refresh()
            if let panel {
                NSAccessibility.post(element: panel, notification: .announcementRequested,
                                     userInfo: [.announcement: "此項目已不存在，請重新選擇。", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
            return
        }
        let action = perform
        close(restoreFocus: false)
        hostWindow?.makeKey()
        DispatchQueue.main.async { action(id) }
    }

    private func position() {
        guard let parent = hostWindow, let panel else { return }
        let size = NSSize(width: min(600, parent.frame.width - 40), height: min(500, parent.frame.height - 110))
        panel.setFrame(NSRect(x: parent.frame.midX - size.width / 2,
                             y: parent.frame.maxY - size.height - 70,
                             width: size.width, height: size.height), display: true)
    }

    static func isComposing(in window: NSWindow) -> Bool {
        (window.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    private func installEvents() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window === self.hostWindow {
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    // Keep the child present for the entire event dispatch so
                    // other pre-existing mouse monitors see the blocking state.
                    DispatchQueue.main.async { self.close() }
                }
                return nil
            }
            guard event.window === panel, event.type == .keyDown else { return event }
            guard !Self.isComposing(in: panel) else { return event }
            if self.shortcuts?.action(matching: event) == .openQuickActions {
                if !event.isARepeat { self.close() }
                return nil
            }
            if event.keyCode == 13, AppShortcutModifiers.from(event.modifierFlags) == [.command] {
                self.close(); return nil
            }
            return event
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.close(restoreFocus: false) })
        notifications.append(center.addObserver(forName: NSWindow.willCloseNotification, object: hostWindow, queue: .main) { [weak self] _ in self?.close(restoreFocus: false) })
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            notifications.append(center.addObserver(forName: name, object: hostWindow, queue: .main) { [weak self] _ in self?.position() })
        }
    }

    func windowDidResignKey(_ notification: Notification) { close(restoreFocus: false) }
}

private struct QuickActionPanelView: View {
    @ObservedObject var controller: QuickActionPanelController
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppVisualTheme.accent)
                QuickActionSearchField(controller: controller).frame(height: 30)
                Button("Esc") { controller.close() }.buttonStyle(.borderless)
            }.padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if controller.results.isEmpty {
                            Text(controller.inputHint ?? "找不到符合的主機、分頁或操作").foregroundStyle(AppVisualTheme.secondaryText).padding(20)
                        }
                        ForEach(QuickActionItem.Section.allCases, id: \.rawValue) { section in
                            let rows = controller.results.filter { $0.section == section }
                            if !rows.isEmpty {
                                Text(section.title).font(.caption).foregroundStyle(AppVisualTheme.secondaryText).padding(.horizontal, 12).padding(.top, 8)
                                ForEach(rows) { item in
                                    Button { controller.execute(item.id) } label: {
                                        HStack(spacing: 12) {
                                            if let platform = item.platform {
                                                HostPlatformBadge(platform: platform, size: 24)
                                            } else {
                                                Image(systemName: item.symbol).frame(width: 24).foregroundStyle(AppVisualTheme.accent)
                                            }
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(item.title).lineLimit(1)
                                                if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(AppVisualTheme.secondaryText).lineLimit(1).truncationMode(.middle) }
                                            }
                                            Spacer(minLength: 8)
                                            Text(item.hint).font(.caption).foregroundStyle(AppVisualTheme.secondaryText)
                                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(controller.selectedID == item.id ? AppVisualTheme.selectedSurface : Color.clear)
                                            .clipShape(.rect(cornerRadius: 8))
                                            // Include transparent Spacer/padding in both hover
                                            // tracking and the plain button's click target.
                                            .contentShape(Rectangle())
                                            .onContinuousHover { phase in
                                                if case .active = phase { controller.hover(item.id) }
                                            }
                                    }.buttonStyle(.plain).id(item.id)
                                        .accessibilityLabel("\(item.title)，\(item.detail)，\(item.hint)" + (item.platform.map { "，\($0.title)" } ?? ""))
                                        .accessibilityAddTraits(controller.selectedID == item.id ? .isSelected : [])
                                }
                            }
                        }
                    }.padding(8)
                }.onChange(of: controller.scrollSelectionRevision) { _, _ in
                    if let id = controller.selectedID { proxy.scrollTo(id) }
                }
            }
            Divider()
            HStack {
                Text("↑ ↓ 選擇　↵ 開啟　Esc 關閉")
                Spacer()
                Text(controller.shortcutLabel)
            }.font(.caption).foregroundStyle(AppVisualTheme.secondaryText).padding(12)
        }.foregroundStyle(AppVisualTheme.primaryText).background(AppVisualTheme.raisedSurface)
            .clipShape(.rect(cornerRadius: 14))
    }
}

private struct QuickActionSearchField: NSViewRepresentable {
    let controller: QuickActionPanelController
    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: "")
        field.placeholderString = "搜尋主機、分頁、操作，或輸入 帳號@主機"
        field.setAccessibilityLabel("搜尋或輸入帳號@主機快速連線")
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 17)
        field.delegate = context.coordinator
        controller.searchField = field
        return field
    }
    func updateNSView(_ nsView: NSTextField, context: Context) { }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let controller: QuickActionPanelController
        init(_ controller: QuickActionPanelController) { self.controller = controller }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            controller.search(field.stringValue)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): controller.move(1)
            case #selector(NSResponder.moveUp(_:)): controller.move(-1)
            case #selector(NSResponder.insertNewline(_:)): controller.execute(controller.selectedID)
            case #selector(NSResponder.cancelOperation(_:)): controller.close()
            default: return false
            }
            return true
        }
    }
}

struct QuickActionWindowAnchor: NSViewRepresentable {
    let controller: QuickActionPanelController
    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView(); view.controller = controller; return view
    }
    func updateNSView(_ nsView: AnchorView, context: Context) { controller.hostWindow = nsView.window }
    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) { nsView.controller?.dispose() }
    final class AnchorView: NSView {
        weak var controller: QuickActionPanelController?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); controller?.hostWindow = window }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct QuickActionMenuKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var openQuickActions: (() -> Void)? {
        get { self[QuickActionMenuKey.self] }
        set { self[QuickActionMenuKey.self] = newValue }
    }
}

struct QuickActionCommands: Commands {
    @FocusedValue(\.openQuickActions) private var open
    @ObservedObject var shortcuts: AppShortcutStore
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            // Key handling stays in AppShortcutMonitorView; displaying the
            // assignment here must not register a second keyboard handler.
            Button("快速操作…" + (shortcuts.shortcut(for: .openQuickActions).map { "　" + $0.displayText } ?? "")) { open?() }
                .disabled(open == nil)
        }
    }
}
