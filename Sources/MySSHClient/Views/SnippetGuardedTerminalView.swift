import AppKit
import SwiftTerm

// Use protocol state, never the command name or screen text. Interactive tools
// can draw on the normal buffer (notably top). Cursor state must change before
// the asynchronous visual update so the send boundary cannot see stale state.
class SnippetGuardedTerminalView: LocalProcessTerminalView {
    private var snippetCursorVisible = true
    private var pendingCaretVisibility: Bool?
    private var pendingCaretVisibilityFlush: DispatchWorkItem?

    var allowsSnippetInTerminalMode: Bool {
        let terminal = getTerminal()
        return snippetCursorVisible && !terminal.isCurrentBufferAlternate && terminal.mouseMode == .off
    }

    deinit { pendingCaretVisibilityFlush?.cancel() }

    override func showCursor(source: Terminal) {
        snippetCursorVisible = true
        scheduleCaretVisibility(true, source: source)
    }

    override func hideCursor(source: Terminal) {
        snippetCursorVisible = false
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

}
