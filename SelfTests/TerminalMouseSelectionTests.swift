import AppKit
@testable import SwiftTerm

private final class SelectionTestView: LocalProcessTerminalView {
    var reports: [UInt8] = []
    var openedLinks = 0
    override func send(source: TerminalView, data: ArraySlice<UInt8>) { reports += data }
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        openedLinks += 1
    }
}

@main
struct TerminalMouseSelectionTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("\(condition ? "PASS" : "FAIL"): \(message)")
        }

        // No process, credentials or real terminal output: exercise the actual
        // AppKit handlers and renderer with deterministic pointer events.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let view = SelectionTestView(frame: NSRect(x: 31, y: 47, width: 800, height: 600))
        window.contentView!.addSubview(view)
        view.lineSpacing = TerminalTypography.lineSpacing
        view.applyTerminalFontSize(14)
        var eventNumber = 0
        func event(_ type: NSEvent.EventType, col: CGFloat, row: CGFloat = 2,
                   flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
            eventNumber += 1
            let point = NSPoint(x: (col + 0.25) * view.cellDimension.width,
                                y: view.frame.height - (row + 0.5) * view.cellDimension.height)
            return NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                                      modifierFlags: flags, timestamp: Double(eventNumber) / 60,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: eventNumber, clickCount: clicks, pressure: 1)!
        }
        func load(_ text: String = "ABC1234567") {
            view.feed(text: "\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?7h\u{1b}[H\u{1b}[2J\u{1b}[3J\u{1b}[3;1H" + text)
            view.selection.selectNone()
        }
        func drag(from: CGFloat, first: CGFloat, to: CGFloat, flags: NSEvent.ModifierFlags = []) {
            view.mouseDown(with: event(.leftMouseDown, col: from, flags: flags))
            view.mouseDragged(with: event(.leftMouseDragged, col: first, flags: flags))
            view.mouseDragged(with: event(.leftMouseDragged, col: to, flags: flags))
            view.mouseUp(with: event(.leftMouseUp, col: to, flags: flags))
        }

        load()
        view.mouseDown(with: event(.leftMouseDown, col: 0))
        check(!view.selection.active, "starting a gesture does not select text before dragging")
        view.mouseDragged(with: event(.leftMouseDragged, col: 1))
        check(view.selection.getSelectedText() == "A", "first drag already includes the original A cell")
        view.mouseDragged(with: event(.leftMouseDragged, col: 10))
        view.mouseUp(with: event(.leftMouseUp, col: 10))
        check(view.selection.getSelectedText() == "ABC1234567", "first-column drag copies the complete string")
        check(view.selectedColumnsRange(row: 2, cols: view.getTerminal().cols) == 0..<10,
              "renderer highlights the same complete range")

        for fraction: CGFloat in [-0.24, 0.25, 0.74] {
            load("prefix ABC1234567")
            drag(from: 7 + fraction, first: 13, to: 17)
            check(view.selection.getSelectedText() == "ABC1234567", "midline start at cell fraction \(fraction + 0.25)")
        }
        load()
        drag(from: 0, first: 10, to: 10)
        check(view.selection.getSelectedText() == "ABC1234567", "a single large drag movement retains its start")
        load()
        drag(from: 10, first: 8, to: 0)
        check(view.selection.getSelectedText() == "ABC1234567", "reverse drag preserves the original endpoint")
        load()
        view.mouseDown(with: event(.leftMouseDown, col: 3))
        view.mouseDragged(with: event(.leftMouseDragged, col: 1))
        check(view.selection.getSelectedText() == "BC", "drag can extend left of its start")
        view.mouseDragged(with: event(.leftMouseDragged, col: 6))
        view.mouseUp(with: event(.leftMouseUp, col: 6))
        check(view.selection.getSelectedText() == "123", "reversing across the start keeps the same anchor")
        view.mouseDown(with: event(.leftMouseDown, col: 0))
        view.mouseUp(with: event(.leftMouseUp, col: 0))
        check(!view.selection.active, "click without dragging clears an old selection")
        view.mouseDragged(with: event(.leftMouseDragged, col: 4))
        check(!view.selection.active, "released click does not seed a later orphan drag")

        for size in [10, 14, 32] {
            view.applyTerminalFontSize(size)
            load()
            drag(from: 0, first: 4, to: 10)
            check(view.selection.getSelectedText() == "ABC1234567", "first column at font size \(size)")
        }
        view.applyTerminalFontSize(14)
        load("A中文e\u{301}Z")
        drag(from: 0, first: 3, to: 7)
        check(view.selection.getSelectedText() == "A中文e\u{301}Z", "CJK and combining characters remain intact")
        load("A🙂B")
        drag(from: 0, first: 3, to: 4)
        check(view.selection.getSelectedText() == "A🙂B", "wide emoji remains intact")

        load("ABC1234567\r\nNEXT")
        view.mouseDown(with: event(.leftMouseDown, col: 0))
        view.mouseDragged(with: event(.leftMouseDragged, col: 1))
        view.mouseDragged(with: event(.leftMouseDragged, col: 4, row: 3))
        view.mouseUp(with: event(.leftMouseUp, col: 4, row: 3))
        check(view.selection.getSelectedText() == "ABC1234567\nNEXT", "multiline copy preserves the first character and newline")
        let cols = view.getTerminal().cols
        load(String(repeating: "x", count: cols - 2) + "ABCD")
        view.mouseDown(with: event(.leftMouseDown, col: CGFloat(cols - 2)))
        view.mouseDragged(with: event(.leftMouseDragged, col: 1, row: 3))
        view.mouseDragged(with: event(.leftMouseDragged, col: 2, row: 3))
        view.mouseUp(with: event(.leftMouseUp, col: 2, row: 3))
        let wrappedCopy = view.selection.getSelectedText()
        check(wrappedCopy == "ABCD", "soft-wrapped text retains its start: \(wrappedCopy.debugDescription)")

        load()
        drag(from: 0, first: 1, to: 3)
        view.mouseDown(with: event(.leftMouseDown, col: 6, flags: .shift))
        view.mouseUp(with: event(.leftMouseUp, col: 6, flags: .shift))
        check(view.selection.getSelectedText() == "ABC123", "Shift click extends an existing selection")
        load("zero alpha beta")
        view.mouseDown(with: event(.leftMouseDown, col: 7, clicks: 2))
        check(view.selection.getSelectedText() == "alpha", "double click keeps word selection")
        view.mouseDragged(with: event(.leftMouseDragged, col: 13, clicks: 2))
        view.mouseUp(with: event(.leftMouseUp, col: 13, clicks: 2))
        check(view.selection.getSelectedText() == "alpha beta", "word drag keeps whole words")
        load()
        view.mouseDown(with: event(.leftMouseDown, col: 4, clicks: 3))
        view.mouseUp(with: event(.leftMouseUp, col: 4, clicks: 3))
        check(view.selection.getSelectedText().trimmingCharacters(in: .whitespacesAndNewlines) == "ABC1234567",
              "triple click keeps row selection")

        load()
        view.mouseDown(with: event(.leftMouseDown, col: 0))
        _ = view.resignFirstResponder()
        view.mouseDragged(with: event(.leftMouseDragged, col: 5))
        check(!view.selection.active, "focus loss cancels a pending start")
        view.mouseDown(with: event(.leftMouseDown, col: 0))
        view.removeFromSuperview()
        window.contentView!.addSubview(view)
        view.mouseDragged(with: event(.leftMouseDragged, col: 5))
        check(!view.selection.active, "moving a pane cancels a pending start")
        view.mouseDown(with: event(.leftMouseDown, col: 0))
        view.feed(text: "\u{1b}[?1049hOTHER")
        view.mouseDragged(with: event(.leftMouseDragged, col: 5))
        check(!view.selection.active, "changing buffers rejects the previous buffer's anchor")
        view.mouseUp(with: event(.leftMouseUp, col: 5))

        load()
        view.allowMouseReporting = true
        view.feed(text: "\u{1b}[?1002h")
        view.reports = []
        drag(from: 0, first: 1, to: 10)
        check(!view.selection.active && !view.reports.isEmpty, "TUI receives its mouse reports without local selection")
        view.reports = []
        drag(from: 0, first: 2, to: 10, flags: .shift)
        check(view.selection.getSelectedText() == "ABC1234567" && view.reports.isEmpty,
              "existing Shift bypass selects locally without sending TUI mouse reports")

        load("\u{1b}]8;;https://example.invalid/\u{1b}\\ABC1234567\u{1b}]8;;\u{1b}\\")
        view.mouseDown(with: event(.leftMouseDown, col: 1, flags: .command))
        view.mouseUp(with: event(.leftMouseUp, col: 1, flags: .command))
        check(view.openedLinks == 1, "normal link click still requests opening")
        drag(from: 0, first: 2, to: 5, flags: .command)
        check(view.openedLinks == 1 && view.selection.getSelectedText() == "ABC12",
              "selecting through a link does not open it on release")

        load()
        view.feed(text: (0..<70).map { "line\($0) ABC1234567\r\n" }.joined())
        view.scrollUp(lines: 5)
        let buffer = view.getTerminal().displayBuffer
        let expectedRow = buffer.yDisp + 2
        let expectedText = view.getTerminal().getDisplayText(start: Position(col: 0, row: expectedRow),
                                                            end: Position(col: 8, row: expectedRow))
        drag(from: 0, first: 3, to: 8)
        check(view.selection.start.row == expectedRow && view.selection.getSelectedText() == expectedText,
              "selection uses the scrolled buffer row, not the visible row number")
        view.mouseDown(with: event(.leftMouseDown, col: 0))
        view.scrollUp(lines: 1)
        view.mouseDragged(with: event(.leftMouseDragged, col: 8, row: 3))
        view.mouseUp(with: event(.leftMouseUp, col: 8, row: 3))
        check(view.selection.start.row == expectedRow && view.selection.getSelectedText() == expectedText,
              "scrolling before the first drag preserves the original buffer anchor")
        print("\n\(passed) terminal mouse selection checks passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
