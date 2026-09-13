import AppKit
@testable import SwiftTerm

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

        func makeView(spacing: CGFloat = TerminalTypography.lineSpacing) -> LocalProcessTerminalView {
            let result = LocalProcessTerminalView(frame: .zero)
            result.lineSpacing = spacing
            result.applyTerminalFontSize(14)
            result.setFrameSize(NSSize(width: 800, height: 600))
            return result
        }
        let view = makeView()
        let reference = makeView(spacing: 1.0)
        check(view.font == reference.font && view.cellDimension.width == reference.cellDimension.width &&
              view.getTerminal().cols == reference.getTerminal().cols,
              "increased line spacing leaves font, cell width and column count unchanged")
        check(view.cellDimension.height > reference.cellDimension.height &&
              view.getTerminal().rows < reference.getTerminal().rows &&
              view.getTerminal().rows == Int(view.bounds.height / view.cellDimension.height),
              "increased cell height determines the actual terminal row count")
        check(view.caretFrame.height == view.cellDimension.height,
              "cursor height follows the increased terminal cell height")
        print("METRICS: font=\(view.font.fontName) 14pt, cell=\(reference.cellDimension.width)x\(reference.cellDimension.height) -> \(view.cellDimension.width)x\(view.cellDimension.height), grid=\(reference.getTerminal().cols)x\(reference.getTerminal().rows) -> \(view.getTerminal().cols)x\(view.getTerminal().rows)")
        let terminal = view.getTerminal()
        let originalSize = view.frame.size
        let originalColumns = terminal.cols
        view.feed(text: "HISTORY\r\n\r\n\u{1B}[?1h\u{1B}[?1000h\u{1B}[?2004h\u{1B}[31mPROMPT> ")
        let cursor = terminal.getCursorLocation()
        let second = makeView()
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
        for size in 10...32 {
            view.applyTerminalFontSize(size)
            check(view.lineSpacing == TerminalTypography.lineSpacing &&
                  view.getTerminal().rows == Int(view.bounds.height / view.cellDimension.height) &&
                  view.caretFrame.height == view.cellDimension.height,
                  "font size \(size) preserves line spacing and cursor/grid geometry")
        }
        view.applyTerminalFontSize(14)
        let textView = makeView()
        let sample = "A中文e\u{301}\u{1B}[41mBG\u{1B}[0m\r\nNEXT"
        textView.feed(text: sample)
        reference.feed(text: sample)
        let textTerminal = textView.getTerminal()
        let referenceTerminal = reference.getTerminal()
        var sameCells = true
        for row in 0...1 {
            for col in 0..<12 {
                let actual = textTerminal.getCharData(col: col, row: row)
                let expected = referenceTerminal.getCharData(col: col, row: row)
                sameCells = sameCells && actual?.width == expected?.width &&
                    actual?.attribute == expected?.attribute &&
                    textTerminal.getCharacter(col: col, row: row) == referenceTerminal.getCharacter(col: col, row: row)
            }
        }
        check(sameCells, "line spacing preserves CJK, combining characters, ANSI backgrounds and line breaks")
        for candidate in [textView, reference] {
            candidate.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 4, row: 1))
        }
        check(textView.selection.getSelectedText() == reference.selection.getSelectedText() &&
              textView.selection.getSelectedText().contains("中文"),
              "multiline selection yields identical original text with increased spacing")
        let firstLine = textView.buildAttributedString(row: 0, line: textTerminal.getLine(row: 0)!, cols: textTerminal.cols)
        check(!firstLine.segments.isEmpty, "real renderer builds mixed-width selected text at increased spacing")
        let originalFrame = textView.frame.size
        textView.setFrameSize(NSSize(width: 600, height: 400))
        textView.setFrameSize(originalFrame)
        check(textView.lineSpacing == TerminalTypography.lineSpacing &&
              textTerminal.cols == referenceTerminal.cols && textTerminal.rows == view.getTerminal().rows,
              "pane resizing preserves line spacing and restores terminal dimensions")
        print("\n\(passed) terminal font tests passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
