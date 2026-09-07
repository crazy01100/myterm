import AppKit
import SwiftTerm

enum TerminalMessageHighlight {
    static let storageKey = "terminalMessageHighlightEnabled"

    enum Level: CaseIterable {
        case info, warning, pass, success, error, debug, hint

        init?(label: String) {
            switch label.uppercased() {
            case "資訊", "INFO": self = .info
            case "警告", "WARN", "WARNING": self = .warning
            case "合格", "PASS": self = .pass
            case "成功", "SUCCESS", "OK": self = .success
            case "錯誤", "ERROR", "FAIL": self = .error
            case "除錯", "DEBUG": self = .debug
            case "提示", "HINT": self = .hint
            default: return nil
            }
        }

        func color(isDark: Bool) -> NSColor {
            let rgb: UInt32
            switch (self, isDark) {
            case (.info, false): rgb = 0x255DAD
            case (.warning, false): rgb = 0xA6540B
            case (.pass, false): rgb = 0x006D80
            case (.success, false): rgb = 0x397324
            case (.error, false): rgb = 0xB52F45
            case (.debug, false): rgb = 0x85469C
            case (.hint, false): rgb = 0x56657A
            case (.info, true): rgb = 0x9DBFFF
            case (.warning, true): rgb = 0xF2B46F
            case (.pass, true): rgb = 0x69D4E6
            case (.success, true): rgb = 0xACD986
            case (.error, true): rgb = 0xF39DA7
            case (.debug, true): rgb = 0xD3AFEF
            case (.hint, true): rgb = 0xB5C2D5
            }
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }

    // Bound work to a short prefix of the line currently being drawn. No stored
    // copy of output, stream rewriting, scrollback traversal or per-frame Task.
    static func match(terminal: Terminal, line: BufferLine, columns: Int, isDark: Bool)
        -> (columns: Range<Int>, color: NSColor)? {
        guard !terminal.isCurrentBufferAlternate, !line.isWrapped else { return nil }
        let limit = min(columns, 48)
        var column = 0
        var start: Int?
        var label = ""
        while column < limit {
            let cell = line[column]
            let style = cell.attribute.style
            // Keep explicit backgrounds and application emphasis in control.
            guard cell.attribute.bg == .defaultColor,
                  !style.contains(.invisible), !style.contains(.inverse), !style.contains(.dim) else { return nil }
            let char = terminal.getCharacter(for: cell)
            let width = max(1, Int(cell.width))
            if start == nil {
                if char == " " { column += width; continue }
                guard char == "[" else { return nil }
                start = column
            } else if char == "]" {
                guard let level = Level(label: label), let start else { return nil }
                return (start..<(column + width), level.color(isDark: isDark))
            } else {
                label.append(char)
            }
            column += width
        }
        return nil
    }

    static func apply(to view: LocalProcessTerminalView, enabled: Bool, isDark: Bool) {
        if enabled {
            view.displayLineHighlight = { terminal, line, columns in
                match(terminal: terminal, line: line, columns: columns, isDark: isDark)
            }
        } else {
            view.displayLineHighlight = nil
        }
    }
}

enum TerminalNeutralContrast {
    static func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        let channels = [c.redComponent, c.greenComponent, c.blueComponent].map { value in
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }

    static func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func foreground(attribute: Attribute, foreground: NSColor, background: NSColor) -> NSColor {
        guard !attribute.style.contains(.invisible), !attribute.style.contains(.inverse),
              !attribute.style.contains(.dim),
              case .ansi256(let index) = attribute.fg, [0, 7, 8, 15].contains(Int(index)),
              ratio(foreground, background) < 4.5 else { return foreground }
        // The raw palette remains white/black. Only a low-contrast neutral
        // foreground is corrected against its actual background at render time.
        let dark = NSColor(srgbRed: 0.23, green: 0.28, blue: 0.35, alpha: 1)
        let light = NSColor(srgbRed: 0.88, green: 0.92, blue: 0.97, alpha: 1)
        let candidate = ratio(dark, background) > ratio(light, background) ? dark : light
        if ratio(candidate, background) >= 4.5 { return candidate }
        return ratio(.black, background) > ratio(.white, background) ? .black : .white
    }
}
