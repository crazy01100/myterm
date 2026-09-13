import AppKit
import SwiftTerm

private final class PaletteProbeView: LocalProcessTerminalView {
    var replies: [UInt8] = []
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        replies.append(contentsOf: data)
    }
    func query(_ index: Int) -> String {
        replies.removeAll()
        feed(text: "\u{1B}]4;\(index);?\u{07}")
        return String(decoding: replies, as: UTF8.self)
    }
}

@main
struct TerminalOutputThemeTests {
    static func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB)!
        let channels = [c.redComponent, c.greenComponent, c.blueComponent].map { value in
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    static func xcolor(_ rgb: UInt32) -> String {
        String(format: "rgb:%04x/%04x/%04x", ((rgb >> 16) & 255) * 257,
               ((rgb >> 8) & 255) * 257, (rgb & 255) * 257)
    }
    @MainActor
    static func main() {
        _ = NSApplication.shared
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("\(condition ? "PASS" : "FAIL"): \(message)")
        }
        let view = PaletteProbeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.lineSpacing = TerminalTypography.lineSpacing
        view.applyTerminalFontSize(14)
        let reference = PaletteProbeView(frame: view.frame)
        reference.getTerminal().ansi256PaletteStrategy = .xterm
        let originalExtendedPalette = (16..<256).map { reference.query($0) }
        for (name, theme) in [("light", TerminalOutputTheme.light), ("dark", .dark)] {
            theme.apply(to: view)
            check(theme.ansiRGB.count == 16, "\(name) has exactly 16 ANSI slots")
            for index in 0..<16 {
                check(view.query(index).contains(xcolor(theme.ansiRGB[index])),
                      "\(name) actual renderer palette slot \(index)")
            }
            for index in [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14] {
                let rgb = theme.ansiRGB[index]
                let color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                                    green: CGFloat((rgb >> 8) & 255) / 255,
                                    blue: CGFloat(rgb & 255) / 255, alpha: 1)
                check(contrast(color, theme.background) >= 4.5,
                      "\(name) chromatic slot \(index) contrast >= 4.5:1")
            }
            check(contrast(theme.foreground, theme.background) >= 4.5, "\(name) default text contrast")
            check(contrast(theme.selectionForeground, theme.selectionBackground) >= 4.5,
                  "\(name) selected text contrast")
            check((16..<256).map { view.query($0) } == originalExtendedPalette &&
                  originalExtendedPalette.allSatisfy { !$0.isEmpty },
                  "\(name) all 240 xterm extended colors unchanged")
            check(view.query(196).contains(xcolor(0xFF0000)) &&
                  view.query(244).contains(xcolor(0x808080)), "\(name) standard xterm red and gray")
            view.feed(text: "\u{1B}]4;3;rgb:ffff/0000/0000\u{07}")
            check(view.query(3).contains(xcolor(0xFF0000)), "\(name) application OSC palette override works")
            view.feed(text: "\u{1B}]104\u{07}")
            check(view.query(3).contains(xcolor(theme.ansiRGB[3])), "\(name) OSC 104 restores theme defaults")
            view.getTerminal().softReset()
            check(view.query(11).contains(xcolor(theme.ansiRGB[11])), "\(name) reconnect soft reset retains theme")
        }
        view.feed(text: "\u{1B}[H\u{1B}[2J\u{1B}[38;2;12;34;56mR\u{1B}[38;5;196mI\u{1B}[33mY")
        let terminal = view.getTerminal()
        check(terminal.getCharData(col: 0, row: 0)?.attribute.fg == .trueColor(red: 12, green: 34, blue: 56),
              "true-color RGB remains exact")
        check(terminal.getCharData(col: 1, row: 0)?.attribute.fg == .ansi256(code: 196),
              "indexed color remains an index")
        let cursor = terminal.getCursorLocation()
        let attribute = terminal.getCharData(col: 2, row: 0)?.attribute
        view.feed(text: "\u{1B}[?1h\u{1B}[?1000h\u{1B}[?2004h")
        TerminalOutputTheme.light.apply(to: view)
        check(terminal.getCursorLocation() == cursor && terminal.getCharacter(col: 0, row: 0) == "R" &&
              terminal.getCharData(col: 2, row: 0)?.attribute == attribute,
              "theme switch preserves content, cursor and attributes")
        check(terminal.applicationCursor && terminal.mouseMode != .off && terminal.bracketedPasteMode,
              "theme switch preserves input modes")
        view.applyTerminalFontSize(18)
        check(view.query(3).contains(xcolor(TerminalOutputTheme.light.ansiRGB[3])),
              "font zoom preserves theme palette")
        view.feed(text: "\u{1B}[?1049h\u{1B}[HALT")
        TerminalOutputTheme.dark.apply(to: view)
        check(terminal.isCurrentBufferAlternate && terminal.getCharacter(col: 0, row: 0) == "A",
              "theme switch preserves alternate-screen content")
        view.feed(text: "\u{1B}[?1049l")
        check(terminal.getCharacter(col: 0, row: 0) == "R", "normal content survives themed alternate screen")
        print("\n\(passed) terminal color tests passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
