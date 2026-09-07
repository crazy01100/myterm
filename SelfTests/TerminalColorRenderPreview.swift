import AppKit
import SwiftTerm

/// Offline previews using the actual vendored AppKit renderer, not a mockup.
@main
struct TerminalColorRenderPreview {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count == 2 else {
            print("Usage: TerminalColorRenderPreview OUTPUT_DIRECTORY")
            exit(64)
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [FileManager.default.currentDirectoryPath + "/SelfTests/terminal-color-preview.sh"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { exit(1) }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
        let frame = NSRect(x: 0, y: 0, width: 1120, height: 1000)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let view = LocalProcessTerminalView(frame: frame)
        window.contentView = view
        view.wantsLayer = true
        view.applyTerminalFontSize(19)
        for dark in [false, true] {
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            (dark ? TerminalOutputTheme.dark : .light).apply(to: view)
            TerminalMessageHighlight.apply(to: view, enabled: true, isDark: dark)
            view.feed(text: "\u{1B}[0m\u{1B}[H\u{1B}[2J" + text)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            let file = output.appendingPathComponent(dark ? "terminal-dark.png" : "terminal-light.png")
            try png.write(to: file)
            print(file.path)
        }
    }
}
