import AppKit
@testable import SwiftTerm

@main
struct TerminalMessageHighlightTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("\(condition ? "PASS" : "FAIL"): \(message)")
        }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 620))
        view.lineSpacing = TerminalTypography.lineSpacing
        view.applyTerminalFontSize(16)
        let t = view.getTerminal()
        func load(_ text: String) {
            view.feed(text: "\u{1B}[?1049l\u{1B}[0m\u{1B}[H\u{1B}[2J" + text)
        }
        func match(_ text: String, isDark: Bool = false) -> (columns: Range<Int>, color: NSColor)? {
            load(text)
            return TerminalMessageHighlight.match(terminal: t, line: t.getLine(row: 0)!, columns: t.cols, isDark: isDark)
        }
        func rendered() -> NSAttributedString {
            let result = NSMutableAttributedString(string: "")
            for segment in view.buildAttributedString(row: 0, line: t.getLine(row: 0)!, cols: t.cols).segments {
                result.append(segment.attributedString)
            }
            return result
        }
        for (label, level) in [("資訊", TerminalMessageHighlight.Level.info), ("警告", .warning),
                               ("合格", .pass), ("成功", .success), ("錯誤", .error), ("除錯", .debug), ("提示", .hint),
                               ("info", .info), ("WARN", .warning), ("warning", .warning), ("PASS", .pass),
                               ("SUCCESS", .success), ("OK", .success), ("ERROR", .error), ("FAIL", .error),
                               ("debug", .debug), ("HINT", .hint)] {
            check(match("[\(label)] message")?.color == level.color(isDark: false), "recognizes [\(label)]")
        }
        check(match("  [資訊] 中文")?.columns == 2..<8, "CJK prefix maps to terminal columns including indentation")
        for text in ["plain [INFO]", "[OTHER]", "[INFO", "2026 [INFO]", "[information]", "[WARNED]", "[INFO extra]",
                     String(repeating: " ", count: 48) + "[INFO]",
                     "\u{1B}[7m[INFO]", "\u{1B}[8m[INFO]", "\u{1B}[2m[INFO]", "\u{1B}[40m[INFO]"] {
            check(match(text) == nil, "excludes non-label / protected text: \(text.debugDescription)")
        }
        load("[IN")
        view.feed(text: "FO] split")
        check(TerminalMessageHighlight.match(terminal: t, line: t.getLine(row: 0)!, columns: t.cols, isDark: false) != nil,
              "split output uses parsed cells, not stream chunk boundaries")
        view.feed(text: "\r\u{1B}[2Kreplaced")
        check(TerminalMessageHighlight.match(terminal: t, line: t.getLine(row: 0)!, columns: t.cols, isDark: false) == nil,
              "overwritten label does not leave stale highlight")
        load(String(repeating: "x", count: t.cols) + "[INFO]")
        check(TerminalMessageHighlight.match(terminal: t, line: t.getLine(row: 1)!, columns: t.cols, isDark: false) == nil,
              "wrapped continuation is not a logical line start")
        load("\u{1B}[?1049h\u{1B}[H[INFO]")
        check(TerminalMessageHighlight.match(terminal: t, line: t.getLine(row: 0)!, columns: t.cols, isDark: false) == nil,
              "alternate screen is excluded")

        for isDark in [false, true] {
            let theme = isDark ? TerminalOutputTheme.dark : .light
            theme.apply(to: view)
            TerminalMessageHighlight.apply(to: view, enabled: true, isDark: isDark)
            for level in TerminalMessageHighlight.Level.allCases {
                check(TerminalNeutralContrast.ratio(level.color(isDark: isDark), theme.background) >= 4.5,
                      "\(isDark ? "dark" : "light") \(level) contrast >= 4.5")
            }
            load("\u{1B}[33m[INFO] body")
            let original = t.getCharData(col: 0, row: 0)!
            let cursor = t.getCursorLocation()
            let output = rendered()
            check(output.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor ==
                  TerminalMessageHighlight.Level.info.color(isDark: isDark), "actual renderer overrides label foreground")
            check(output.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor !=
                  TerminalMessageHighlight.Level.info.color(isDark: isDark), "actual renderer leaves adjacent body unchanged")
            check(t.getCharData(col: 0, row: 0)?.attribute == original.attribute && t.getCursorLocation() == cursor &&
                  output.string.hasPrefix("[INFO] body"), "display does not mutate text / attributes / cursor")
            // The same range machinery used by mouse selection must win over highlighting.
            view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
            check(rendered().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor ==
                  theme.selectionForeground, "selection wins over message label color")
            check(view.selection.getSelectedText() == "[INFO]", "copy selection retains exact original label text")
            view.selection.active = false
            TerminalMessageHighlight.apply(to: view, enabled: false, isDark: isDark)
            check(rendered().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor !=
                  TerminalMessageHighlight.Level.info.color(isDark: isDark), "toggle restores original label color")
            for code in [30, 37, 90, 97] {
                load("\u{1B}[\(code)mX")
                let attrs = view.getAttributes(t.getCharData(col: 0, row: 0)!.attribute, withUrl: false)!
                check(TerminalNeutralContrast.ratio(attrs[.foregroundColor] as! NSColor, attrs[.backgroundColor] as! NSColor) >= 4.5,
                      "neutral SGR \(code) readable against \(isDark ? "dark" : "light") background")
            }
            load("\u{1B}[40;97mX")
            let attr = t.getCharData(col: 0, row: 0)!.attribute
            let attrs = view.getAttributes(attr, withUrl: false)!
            check(attrs[.foregroundColor] as? NSColor == view.mapColor(color: .ansi256(code: 15), isFg: true, isBold: false),
                  "white on explicit black remains white")
            for sgr in ["7;97", "8;97", "2;97", "38;2;250;250;250", "38;5;255"] {
                load("\u{1B}[\(sgr)mX")
                let attribute = t.getCharData(col: 0, row: 0)!.attribute
                let before = view.getAttributes(attribute, withUrl: false)![.foregroundColor] as! NSColor
                view.displayForegroundTransform = nil
                let unchanged = view.getAttributes(attribute, withUrl: false)![.foregroundColor] as! NSColor
                check(before == unchanged, "preserves protected / explicit color \(sgr)")
                theme.apply(to: view)
            }
        }
        // Small renderer benchmark: output identical content with hooks on/off,
        // bounding work per visible row rather than extrapolating a frame rate.
        load("[INFO] " + String(repeating: "sample ", count: 10))
        for enabled in [false, true] {
            TerminalMessageHighlight.apply(to: view, enabled: enabled, isDark: false)
            let start = Date()
            for _ in 0..<1000 { _ = rendered() }
            print("BENCH: 1000 line builds, highlight=\(enabled), \(Date().timeIntervalSince(start) * 1000) ms")
        }
        print("\n\(passed) terminal highlight tests passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
