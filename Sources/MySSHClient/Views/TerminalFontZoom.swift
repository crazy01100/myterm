import AppKit
import SwiftTerm

enum TerminalTypography {
    static let lineSpacing: CGFloat = 1.15
}

extension LocalProcessTerminalView {
    func applyTerminalFontSize(_ size: Int) {
        let pointSize = CGFloat(size)
        guard font.pointSize != pointSize || font.fontName != "SFMono-Regular" else { return }
        let updatedFont = NSFont(name: "SFMono-Regular", size: pointSize)
            ?? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)

        // SwiftTerm's font setter calls resize(cols:rows:), which performs a
        // DECSTR soft reset. Its normal setFrameSize path resizes without that
        // reset. Use a zero-sized frame only during this synchronous font
        // update, so the setter recalculates glyphs without resetting the live
        // terminal, then restore the frame to notify the PTY normally.
        let previousSize = frame.size
        setFrameSize(.zero)
        font = updatedFont
        setFrameSize(previousSize)
    }
}
