import AppKit
import SwiftUI

/// MyTerm's semantic color system. Feature views consume roles instead of
/// defining ad-hoc RGB values so light and dark appearances stay coordinated.
enum AppVisualTheme {
    static let chromeBackground = color(light: 0x24324A, dark: 0x101A2C)
    static let chromeForeground = color(light: 0xF4F7FC, dark: 0xF4F7FC)
    static let chromeSecondary = color(light: 0xBFCBE0, dark: 0xAFC0D8)
    static let chromeSelectedSurface = color(light: 0x3A4E6C, dark: 0x294463)
    static let chromeSubtleSurface = color(light: 0x2C3C57, dark: 0x18263B)

    static let sidebarBackground = color(light: 0xE8EFF7, dark: 0x19263B)
    static let contentBackground = color(light: 0xF1F6FB, dark: 0x142035)
    static let raisedSurface = color(light: 0xFFFFFF, dark: 0x202E45)
    static let subtleSurface = color(light: 0xE4EDF7, dark: 0x263650)
    static let selectedSurface = color(light: 0xD9E9FC, dark: 0x294D75)
    static let hoverSurface = color(light: 0xE8F1FB, dark: 0x243C5C)
    static let separator = color(light: 0xCAD6E5, dark: 0x344760)
    static let inactiveOutline = color(light: 0xB9C7D8, dark: 0x43566F)
    static let activeOutline = color(light: 0x33445E, dark: 0xAFC4DE)
    static let accent = color(light: 0x2F7DE1, dark: 0x65A8FF)
    static let primaryText = color(light: 0x17243A, dark: 0xF0F5FC)
    static let secondaryText = color(light: 0x65758A, dark: 0xAAB8CA)

    static let contentBackgroundNSColor = nsColor(light: 0xF1F6FB, dark: 0x142035)
    static let separatorNSColor = nsColor(light: 0xCAD6E5, dark: 0x344760)
    static let dividerHandleNSColor = nsColor(light: 0x33445E, dark: 0xAFC4DE)

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: nsColor(light: light, dark: dark))
    }

    private static func nsColor(light: UInt32, dark: UInt32) -> NSColor {
        let lightColor = fixedNSColor(hex: light)
        let darkColor = fixedNSColor(hex: dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? darkColor
                : lightColor
        }
    }

    private static func fixedNSColor(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
