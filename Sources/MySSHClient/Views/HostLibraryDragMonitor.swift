import AppKit
import SwiftUI

/// Tracks host-card drags at the window-event boundary so category targeting
/// is based on measured card rectangles, independent of SwiftUI drop routing.
struct HostLibraryDragMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let beginDrag: (CGPoint) -> HostProfile.ID?
    let changeDrag: (HostProfile.ID, CGPoint) -> Void
    let endDrag: (HostProfile.ID, CGPoint) -> Void
    let cancelDrag: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            beginDrag: beginDrag,
            changeDrag: changeDrag,
            endDrag: endDrag,
            cancelDrag: cancelDrag
        )
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        context.coordinator.setEnabled(isEnabled)
        context.coordinator.beginDrag = beginDrag
        context.coordinator.changeDrag = changeDrag
        context.coordinator.endDrag = endDrag
        context.coordinator.cancelDrag = cancelDrag
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: Coordinator) {
        coordinator.removeMonitor(reason: .viewTeardown)
    }

    final class Coordinator {
        private(set) var isEnabled: Bool
        var beginDrag: (CGPoint) -> HostProfile.ID?
        var changeDrag: (HostProfile.ID, CGPoint) -> Void
        var endDrag: (HostProfile.ID, CGPoint) -> Void
        var cancelDrag: () -> Void
        weak var hostView: MonitorView?

        private var mouseMonitor: Any?
        private var mouseDownPoint: CGPoint?
        private var trackedHostID: HostProfile.ID?
        private var isDragging = false

        init(
            isEnabled: Bool,
            beginDrag: @escaping (CGPoint) -> HostProfile.ID?,
            changeDrag: @escaping (HostProfile.ID, CGPoint) -> Void,
            endDrag: @escaping (HostProfile.ID, CGPoint) -> Void,
            cancelDrag: @escaping () -> Void
        ) {
            self.isEnabled = isEnabled
            self.beginDrag = beginDrag
            self.changeDrag = changeDrag
            self.endDrag = endDrag
            self.cancelDrag = cancelDrag
        }

        func installMonitor() {
            removeMonitor(reason: .monitorReplacement)
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                guard let self, let hostView = self.hostView,
                      event.window === hostView.window else { return event }
                guard event.window?.hasQuickActionPanel != true else { self.reset(); return event }
                guard self.isEnabled else {
                    self.reset()
                    return event
                }
                let point = hostView.convert(event.locationInWindow, from: nil)

                switch event.type {
                case .leftMouseDown:
                    self.mouseDownPoint = point
                    self.trackedHostID = self.beginDrag(point)
                    self.isDragging = false
                case .leftMouseDragged:
                    guard let hostID = self.trackedHostID,
                          let mouseDownPoint = self.mouseDownPoint else { return event }
                    let deltaX = point.x - mouseDownPoint.x
                    let deltaY = point.y - mouseDownPoint.y
                    guard self.isDragging || deltaX * deltaX + deltaY * deltaY >= 16 else {
                        return event
                    }
                    self.isDragging = true
                    self.changeDrag(hostID, point)
                    return nil
                case .leftMouseUp:
                    guard let hostID = self.trackedHostID else {
                        self.reset()
                        return event
                    }
                    let consumed = self.isDragging
                    if consumed {
                        self.endDrag(hostID, point)
                        self.reset()
                    } else {
                        self.cancelTrackedDrag()
                    }
                    return consumed ? nil : event
                default:
                    break
                }
                return event
            }
        }

        func setEnabled(_ isEnabled: Bool) {
            guard self.isEnabled != isEnabled else { return }
            self.isEnabled = isEnabled
            if !isEnabled {
                // HostLibraryView remains mounted behind terminal workspaces
                // to preserve navigation state. Drop all measured-card drag
                // state without notifying SwiftUI when it becomes invisible.
                reset()
            }
        }

        func removeMonitor(reason: HostLibraryDragCleanupReason) {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
            clearTracking(reason: reason)
        }

        func cancelTrackedDrag() {
            clearTracking(reason: .userCancellation)
        }

        private func clearTracking(reason: HostLibraryDragCleanupReason) {
            if reason.notifiesSwiftUICancellation {
                cancelDrag()
            }
            reset()
        }

        private func reset() {
            mouseDownPoint = nil
            trackedHostID = nil
            isDragging = false
        }

        deinit { removeMonitor(reason: .viewTeardown) }
    }

    final class MonitorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
