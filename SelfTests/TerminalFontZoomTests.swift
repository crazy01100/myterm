import AppKit
import SwiftTerm

@main
struct TerminalFontZoomTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("\(condition ? "PASS" : "FAIL"): \(message)")
        }

        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.applyTerminalFontSize(14)
        let terminal = view.getTerminal()
        let originalSize = view.frame.size
        let originalColumns = terminal.cols
        view.feed(text: "HISTORY\r\n\r\n\u{1B}[?1h\u{1B}[?1000h\u{1B}[?2004h\u{1B}[31mPROMPT> ")
        let cursor = terminal.getCursorLocation()
        let second = LocalProcessTerminalView(frame: view.frame)
        second.applyTerminalFontSize(14)
        view.applyTerminalFontSize(20)
        check(view.font.pointSize == 20 && terminal.cols < originalColumns && view.frame.size == originalSize,
              "font change updates terminal grid while preserving the pane frame")
        check(terminal.getCursorLocation() == cursor && terminal.getCharacter(col: 0, row: 0) == "H",
              "font change preserves the live cursor and earlier content")
        check(terminal.applicationCursor && terminal.mouseMode != .off && terminal.bracketedPasteMode,
              "font change preserves application cursor, mouse and paste modes")
        view.feed(text: "X")
        check(terminal.getCharData(col: cursor.x, row: cursor.y)?.attribute ==
              terminal.getCharData(col: 0, row: cursor.y)?.attribute,
              "font change preserves the active ANSI text attributes")
        check(second.font.pointSize == 14,
              "font change leaves other terminal views unchanged")

        view.feed(text: "\u{1B}[?1049h\u{1B}[H\u{1B}[2JALT\r\n\u{1B}[?1h")
        let alternateCursor = terminal.getCursorLocation()
        view.applyTerminalFontSize(10)
        check(terminal.isCurrentBufferAlternate && terminal.applicationCursor &&
              terminal.getCursorLocation() == alternateCursor && terminal.getCharacter(col: 0, row: 0) == "A",
              "font change preserves the alternate screen and its cursor mode")
        view.feed(text: "\u{1B}[?1049l")
        check(terminal.getCharacter(col: 0, row: 0) == "H",
              "normal-screen history survives alternate-screen font changes")
        view.applyTerminalFontSize(14)
        check(view.font.pointSize == 14 && terminal.cols == originalColumns,
              "font reset restores MyTerm size and original grid width")
        print("\n\(passed) terminal font tests passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
