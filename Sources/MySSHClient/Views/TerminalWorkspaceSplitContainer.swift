import AppKit
import SwiftUI

struct TerminalWorkspaceSplitContainer: NSViewRepresentable {
    let sessions: [TerminalSession]
    let selectedWorkspace: TerminalWorkspace?
    let hostStore: HostStore
    let connectionAuditStore: ConnectionAuditStore
    let onActivate: (TerminalSession.ID) -> Void
    let onToggleSplit: (TerminalWorkspace.ID) -> Void
    let onClose: (TerminalSession) -> Void
    let onRetry: (TerminalSession) -> Void
    let onEditHost: (HostProfile) -> Void
    let onRatioCommitted: (TerminalWorkspace.ID, Double) -> Void

    func makeNSView(context: Context) -> TerminalWorkspaceCanvasNSView {
        TerminalWorkspaceCanvasNSView()
    }

    func updateNSView(_ nsView: TerminalWorkspaceCanvasNSView, context: Context) {
        nsView.update(
            sessions: sessions,
            selectedWorkspace: selectedWorkspace,
            hostStore: hostStore,
            connectionAuditStore: connectionAuditStore,
            onActivate: onActivate,
            onToggleSplit: onToggleSplit,
            onClose: onClose,
            onRetry: onRetry,
            onEditHost: onEditHost,
            onRatioCommitted: onRatioCommitted
        )
    }

    static func dismantleNSView(_ nsView: TerminalWorkspaceCanvasNSView, coordinator: ()) {
        nsView.prepareForDismantle()
    }
}

@MainActor
final class TerminalWorkspaceCanvasNSView: NSView {
    private let splitView = TerminalWorkspaceNativeSplitView()
    private var paneHosts: [TerminalSession.ID: NSHostingView<TerminalPaneHostingRoot>] = [:]
    private var panePresentations: [TerminalSession.ID: TerminalPanePresentation] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(
        sessions: [TerminalSession],
        selectedWorkspace: TerminalWorkspace?,
        hostStore: HostStore,
        connectionAuditStore: ConnectionAuditStore,
        onActivate: @escaping (TerminalSession.ID) -> Void,
        onToggleSplit: @escaping (TerminalWorkspace.ID) -> Void,
        onClose: @escaping (TerminalSession) -> Void,
        onRetry: @escaping (TerminalSession) -> Void,
        onEditHost: @escaping (HostProfile) -> Void,
        onRatioCommitted: @escaping (TerminalWorkspace.ID, Double) -> Void
    ) {
        let currentSessionIDs = Set(sessions.map(\.id))
        let staleSessionIDs = paneHosts.keys.filter { !currentSessionIDs.contains($0) }
        for sessionID in staleSessionIDs {
            paneHosts.removeValue(forKey: sessionID)?.removeFromSuperview()
            panePresentations.removeValue(forKey: sessionID)
        }

        let selectedWorkspaceID = selectedWorkspace?.id
        for session in sessions {
            let paneIndex = selectedWorkspace?.sessionIDs.firstIndex(of: session.id)
            let isVisible = paneIndex != nil
            let presentation = TerminalPanePresentation(
                isVisible: isVisible,
                isActive: isVisible && selectedWorkspace?.activeSessionID == session.id,
                workspaceIsSplit: selectedWorkspace?.isSplit == true && isVisible,
                splitAxis: isVisible ? selectedWorkspace?.splitAxis : nil,
                paneIndex: paneIndex,
                workspaceID: isVisible ? selectedWorkspaceID : nil
            )
            let root = TerminalPaneHostingRoot(
                session: session,
                hostStore: hostStore,
                connectionAuditStore: connectionAuditStore,
                isVisible: presentation.isVisible,
                isActive: presentation.isActive,
                workspaceIsSplit: presentation.workspaceIsSplit,
                splitAxis: presentation.splitAxis,
                paneIndex: presentation.paneIndex,
                onActivate: { onActivate(session.id) },
                onToggleSplit: {
                    if let selectedWorkspaceID { onToggleSplit(selectedWorkspaceID) }
                },
                onClose: { onClose(session) },
                onRetry: { onRetry(session) },
                onEditHost: {
                    if let host = session.host { onEditHost(host) }
                }
            )
            if let host = paneHosts[session.id] {
                if panePresentations[session.id] != presentation {
                    host.rootView = root
                }
            } else {
                let host = NSHostingView(rootView: root)
                host.translatesAutoresizingMaskIntoConstraints = true
                paneHosts[session.id] = host
            }
            panePresentations[session.id] = presentation
        }

        let visibleHosts = selectedWorkspace?.sessionIDs.compactMap { paneHosts[$0] } ?? []
        splitView.configure(
            workspace: selectedWorkspace,
            paneHosts: visibleHosts,
            onRatioCommitted: onRatioCommitted
        )
    }

    func prepareForDismantle() {
        splitView.removeAllPanes()
        paneHosts.removeAll()
        panePresentations.removeAll()
    }
}

private struct TerminalPanePresentation: Equatable {
    let isVisible: Bool
    let isActive: Bool
    let workspaceIsSplit: Bool
    let splitAxis: TerminalWorkspaceSplitAxis?
    let paneIndex: Int?
    let workspaceID: TerminalWorkspace.ID?
}

private struct TerminalPaneHostingRoot: View {
    @ObservedObject var session: TerminalSession
    let hostStore: HostStore
    let connectionAuditStore: ConnectionAuditStore
    let isVisible: Bool
    let isActive: Bool
    let workspaceIsSplit: Bool
    let splitAxis: TerminalWorkspaceSplitAxis?
    let paneIndex: Int?
    let onActivate: () -> Void
    let onToggleSplit: () -> Void
    let onClose: () -> Void
    let onRetry: () -> Void
    let onEditHost: () -> Void

    var body: some View {
        TerminalWorkspaceView(
            session: session,
            isVisible: isVisible,
            isActive: isActive,
            workspaceIsSplit: workspaceIsSplit,
            splitAxis: splitAxis,
            paneIndex: paneIndex,
            onActivate: onActivate,
            onToggleSplit: onToggleSplit,
            onClose: onClose,
            onRetry: onRetry,
            onEditHost: onEditHost
        )
        .environmentObject(hostStore)
        .environmentObject(connectionAuditStore)
    }
}

@MainActor
private final class TerminalWorkspaceNativeSplitView: NSSplitView {
    private let splitViewDelegateProxy = TerminalWorkspaceSplitDelegateProxy()
    private var visibleSessionIDs: [TerminalSession.ID] = []
    private var workspaceID: TerminalWorkspace.ID?
    private var modelRatio = 0.5
    private var isTrackingDivider = false
    private var hoveredDivider: Int?
    private var trackingAreaReference: NSTrackingArea?
    private var ratioCommitHandler: ((TerminalWorkspace.ID, Double) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dividerStyle = .thin
        splitViewDelegateProxy.install(on: self)
        autoresizesSubviews = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var dividerThickness: CGFloat { TerminalWorkspaceLayout.dividerThickness }

    func configure(
        workspace: TerminalWorkspace?,
        paneHosts: [NSView],
        onRatioCommitted: @escaping (TerminalWorkspace.ID, Double) -> Void
    ) {
        ratioCommitHandler = onRatioCommitted
        let nextSessionIDs = workspace?.sessionIDs ?? []
        let axisChanged = workspace?.splitAxis.map { isVertical != ($0 == .horizontal) } ?? false
        let panesChanged = nextSessionIDs != visibleSessionIDs

        if panesChanged {
            removeAllPanes()
            for paneHost in paneHosts {
                addArrangedSubview(paneHost)
            }
            visibleSessionIDs = nextSessionIDs
        }

        workspaceID = workspace?.id
        if let splitAxis = workspace?.splitAxis {
            isVertical = splitAxis == .horizontal
        }
        modelRatio = workspace?.splitRatio ?? 0.5

        if panesChanged || axisChanged {
            adjustSubviews()
        }
        applyModelRatioIfNeeded(force: panesChanged || axisChanged)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func removeAllPanes() {
        for subview in arrangedSubviews {
            subview.removeFromSuperview()
        }
        visibleSessionIDs = []
        workspaceID = nil
        hoveredDivider = nil
    }

    override func layout() {
        super.layout()
        applyModelRatioIfNeeded(force: false)
    }

    override func mouseDown(with event: NSEvent) {
        guard arrangedSubviews.count == 2 else {
            super.mouseDown(with: event)
            return
        }
        isTrackingDivider = true
        super.mouseDown(with: event)
        isTrackingDivider = false
        let ratio = currentRatio
        modelRatio = ratio
        if let workspaceID {
            ratioCommitHandler?(workspaceID, ratio)
        }
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let nextHoveredDivider = dividerIndex(near: point)
        if nextHoveredDivider != hoveredDivider {
            hoveredDivider = nextHoveredDivider
            needsDisplay = true
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredDivider = nil
        needsDisplay = true
        super.mouseExited(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard arrangedSubviews.count == 2 else { return }
        let cursor: NSCursor = isVertical ? .resizeLeftRight : .resizeUpDown
        addCursorRect(firstDividerRect.insetBy(dx: isVertical ? -3 : 0, dy: isVertical ? 0 : -3), cursor: cursor)
    }

    override func drawDivider(in rect: NSRect) {
        AppVisualTheme.contentBackgroundNSColor.setFill()
        rect.fill()
        guard hoveredDivider == 0 else { return }
        let handleRect: NSRect
        if isVertical {
            handleRect = NSRect(x: rect.midX - 1.5, y: rect.midY - 19, width: 3, height: 38)
        } else {
            handleRect = NSRect(x: rect.midX - 19, y: rect.midY - 1.5, width: 38, height: 3)
        }
        AppVisualTheme.dividerHandleNSColor.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: handleRect, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private var splitExtent: CGFloat {
        max((isVertical ? bounds.width : bounds.height) - dividerThickness, 0)
    }

    private var currentRatio: Double {
        guard arrangedSubviews.count == 2, splitExtent > 0 else { return modelRatio }
        let firstExtent = isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height
        return min(max(Double(firstExtent / splitExtent), 0.25), 0.75)
    }

    private func applyModelRatioIfNeeded(force: Bool) {
        guard arrangedSubviews.count == 2, splitExtent > 0, !isTrackingDivider else { return }
        let current = currentRatio
        guard force || abs(current - modelRatio) > 0.002 else { return }
        setPosition(splitExtent * CGFloat(modelRatio), ofDividerAt: 0)
    }

    private func dividerIndex(near point: NSPoint) -> Int? {
        guard arrangedSubviews.count == 2 else { return nil }
        let rect = firstDividerRect.insetBy(dx: isVertical ? -3 : 0, dy: isVertical ? 0 : -3)
        return rect.contains(point) ? 0 : nil
    }

    private var firstDividerRect: NSRect {
        guard let firstPane = arrangedSubviews.first else { return .zero }
        if isVertical {
            return NSRect(
                x: firstPane.frame.maxX,
                y: bounds.minY,
                width: dividerThickness,
                height: bounds.height
            )
        }
        return NSRect(
            x: bounds.minX,
            y: firstPane.frame.maxY,
            width: bounds.width,
            height: dividerThickness
        )
    }
}
