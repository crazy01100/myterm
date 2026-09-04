import AppKit

/// Keeps AppKit's optional delegate forwarding away from the split view itself.
/// A self-delegate can recursively re-enter NSSplitView's private sidebar
/// `responds(to:)` path while macOS validates the `toggleSidebar:` menu action.
@MainActor
final class TerminalWorkspaceSplitDelegateProxy: NSObject, NSSplitViewDelegate {
    static let minimumPaneRatio: CGFloat = 0.25
    static let maximumPaneRatio: CGFloat = 0.75

    func install(on splitView: NSSplitView) {
        splitView.delegate = self
        precondition(
            (splitView.delegate as AnyObject?) === self &&
                (splitView.delegate as AnyObject?) !== splitView,
            "Terminal workspace split view must use a separate delegate object"
        )
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(
            proposedMinimumPosition,
            splitExtent(for: splitView) * Self.minimumPaneRatio
        )
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(
            proposedMaximumPosition,
            splitExtent(for: splitView) * Self.maximumPaneRatio
        )
    }

    private func splitExtent(for splitView: NSSplitView) -> CGFloat {
        max(
            (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) -
                splitView.dividerThickness,
            0
        )
    }
}
