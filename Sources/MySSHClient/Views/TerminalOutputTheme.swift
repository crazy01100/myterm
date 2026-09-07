import AppKit
import SwiftTerm

/// Theme defaults for ANSI slots 0...15, not a filter over terminal output.
/// Extended xterm indices and application-supplied RGB retain their meaning.
struct TerminalOutputTheme {
    let ansiRGB: [UInt32]
    let background: NSColor
    let foreground: NSColor
    let caret: NSColor
    let selectionBackground: NSColor
    let selectionForeground: NSColor

    static let light = TerminalOutputTheme(
        ansiRGB: [
            0x1D2B3A, 0xB13E49, 0x207146, 0x8B5E17,
            0x1D5F8A, 0x804B98, 0x1C7078, 0xC6D1DD,
            0x596779, 0xBC3349, 0x227A50, 0x98620C,
            0x17689C, 0x8D469B, 0x117784, 0xF3F7FC
        ],
        background: NSColor(srgbRed: 0.955, green: 0.972, blue: 0.985, alpha: 1),
        foreground: NSColor(srgbRed: 0.13, green: 0.18, blue: 0.28, alpha: 1),
        caret: NSColor(srgbRed: 0.15, green: 0.47, blue: 0.93, alpha: 1),
        selectionBackground: NSColor(srgbRed: 0.72, green: 0.84, blue: 1, alpha: 1),
        selectionForeground: NSColor(srgbRed: 0.07, green: 0.15, blue: 0.25, alpha: 1)
    )

    static let dark = TerminalOutputTheme(
        ansiRGB: [
            0x162131, 0xE58B94, 0x8FC99A, 0xDDBE7C,
            0x83B5E8, 0xBD9DDC, 0x80C7CB, 0xC6D1DD,
            0x8996AA, 0xF3A0A8, 0xA2DDAA, 0xEBD095,
            0xA0C9F2, 0xD2B3ED, 0x9DDDE0, 0xF3F7FC
        ],
        background: NSColor(srgbRed: 0.045, green: 0.070, blue: 0.115, alpha: 1),
        foreground: NSColor(srgbRed: 0.88, green: 0.92, blue: 0.97, alpha: 1),
        caret: NSColor(srgbRed: 0.35, green: 0.78, blue: 1, alpha: 1),
        selectionBackground: NSColor(srgbRed: 0.16, green: 0.33, blue: 0.52, alpha: 1),
        selectionForeground: .white
    )

    func apply(to terminal: LocalProcessTerminalView) {
        terminal.displayForegroundTransform = TerminalNeutralContrast.foreground
        // SwiftTerm defaults to base16Lab, which derives all 256 colors from
        // the base palette/background. Keep explicit extended indices stable.
        terminal.getTerminal().ansi256PaletteStrategy = .xterm
        terminal.nativeForegroundColor = foreground
        terminal.nativeBackgroundColor = background
        terminal.caretColor = caret
        terminal.selectedTextBackgroundColor = selectionBackground
        terminal.selectedTextForegroundColor = selectionForeground
        // Installing also invalidates renderer color caches and establishes
        // defaults for OSC 104 / soft reset. Only run at creation/theme change.
        terminal.installColors(ansiRGB.map { rgb in
            SwiftTerm.Color(red: UInt16((rgb >> 16) & 255) * 257,
                            green: UInt16((rgb >> 8) & 255) * 257,
                            blue: UInt16(rgb & 255) * 257)
        })
        terminal.layer?.backgroundColor = background.cgColor
    }
}
