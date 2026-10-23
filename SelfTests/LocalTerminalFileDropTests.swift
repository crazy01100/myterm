import AppKit
import SwiftTerm

private final class RecordingDropTerminal: FileDropTerminalView {
    var sent: [UInt8] = []
    override func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += data }
}

@main
struct LocalTerminalFileDropTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fatalError("FAIL: \(name)") }
            passed += 1
            print("PASS: \(name)")
        }
        let paths = ["/tmp/photo one.jpeg", "/tmp/中文資料夾", "/tmp/it's a file",
                     "/tmp/$HOME;`literal` $(literal) * ? [x] \\", "/tmp/-option", "/"]
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let text = LocalTerminalFileDrop.text(for: urls)!
        for shell in ["/bin/zsh", "/bin/bash"] {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: shell)
            // Only built-in printf consumes the escaped arguments; no fixture file is executed.
            process.arguments = ["-f", "-c", "printf '%s\\0' " + text]
            process.standardOutput = output
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            check(process.terminationStatus == 0 && bytes == Data((paths.joined(separator: "\0") + "\0").utf8),
                  "\(shell) round-trips exact paths and order without expansion")
        }
        check(LocalTerminalFileDrop.text(for: []) == nil, "empty list rejected")
        check(LocalTerminalFileDrop.text(for: [URL(string: "https://example.com/file")!]) == nil, "web URL rejected")
        check(LocalTerminalFileDrop.text(for: [URL(string: "file://remote/path")!]) == nil, "remote file authority rejected")
        check(LocalTerminalFileDrop.text(for: [URL(string: "file:///tmp/a?query")!]) == nil, "URL query rejected")
        for character in ["\n", "\r", "\t", "\u{1b}", "\u{7f}", "\u{2028}"] {
            check(LocalTerminalFileDrop.text(for: [URL(fileURLWithPath: "/tmp/a" + character + "b")]) == nil,
                  "control/newline path rejected \(character.unicodeScalars.first!.value)")
        }
        check(LocalTerminalFileDrop.text(for: Array(repeating: urls[0], count: 256)) != nil, "256 ordinary files allowed")
        check(LocalTerminalFileDrop.text(for: Array(repeating: urls[0], count: 257)) == nil, "item limit enforced")
        check(LocalTerminalFileDrop.text(for: [URL(fileURLWithPath: "/" + String(repeating: "a", count: 16_381))])?.utf8.count == 16_384,
              "encoded byte limit inclusive")
        check(LocalTerminalFileDrop.text(for: [URL(fileURLWithPath: "/" + String(repeating: "a", count: 16_382))]) == nil,
              "encoded byte overflow rejected")
        check(LocalTerminalFileDrop.text(for: [URL(fileURLWithPath: "/" + String(repeating: "'", count: 5_000))]) == nil,
              "quote expansion included in byte budget")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects(urls as [NSURL])
        check(FileDropTerminalView.fileURLs(from: pasteboard)?.map(\.path) == paths, "real file URL pasteboard round-trip")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = RecordingDropTerminal(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let other = RecordingDropTerminal(frame: NSRect(x: 400, y: 0, width: 400, height: 400))
        window.contentView!.addSubview(view)
        window.contentView!.addSubview(other)
        var target: LocalTerminalFileDropTarget? = .init(sessionID: UUID(), attemptID: UUID())
        var promptGuard = SnippetInputPromptGuard()
        view.fileDropVisible = true
        view.fileDropTarget = { view.allowsSnippetInTerminalMode && !promptGuard.isBlocked ? target : nil }
        view.insertDroppedFiles = { dropped, identity in
            guard identity == target, let text = LocalTerminalFileDrop.text(for: dropped) else { return false }
            view.sendDroppedPathText(text)
            return true
        }
        check(view.beginFileDrop(pasteboard, sequence: 1), "file drag enters eligible pane")
        check(view.finishFileDrop(pasteboard, sequence: 1), "file drop accepted")
        check(view.sent == Array(text.utf8) && other.sent.isEmpty, "only exact destination receives paths without Enter")
        check(!view.finishFileDrop(pasteboard, sequence: 1), "same drop cannot send twice")
        view.feed(text: "\u{1b}[?2004h")
        view.sent = []
        check(view.beginFileDrop(pasteboard, sequence: 2) && view.finishFileDrop(pasteboard, sequence: 2), "bracketed paste drag succeeds")
        check(view.sent == Array(("\u{1b}[200~" + text + "\u{1b}[201~").utf8), "renderer mode adds exact paste delimiters, no Enter")
        check(view.beginFileDrop(pasteboard, sequence: 3), "drag starts before attempt changes")
        target = .init(sessionID: target!.sessionID, attemptID: UUID())
        check(!view.finishFileDrop(pasteboard, sequence: 3), "attempt changes invalidate drag")
        check(view.beginFileDrop(pasteboard, sequence: 4), "drag starts before session closes")
        let original = target
        target = nil
        check(!view.finishFileDrop(pasteboard, sequence: 4), "disconnected target rejected")
        target = original
        check(view.beginFileDrop(pasteboard, sequence: 5), "drag starts before tab hides")
        view.fileDropVisible = false
        check(!view.finishFileDrop(pasteboard, sequence: 5), "inactive tab rejected")
        view.fileDropVisible = true
        check(view.beginFileDrop(pasteboard, sequence: 6), "drag starts before password prompt")
        promptGuard.receive(Array("Password: ".utf8)[...])
        check(!view.finishFileDrop(pasteboard, sequence: 6), "password prompt arriving during drag blocks")
        promptGuard.userInput([3])
        for (enable, disable, name) in [("\u{1b}[?25l", "\u{1b}[?25h", "top"),
                                       ("\u{1b}[?1049h", "\u{1b}[?1049l", "vim"),
                                       ("\u{1b}[?1000h", "\u{1b}[?1000l", "mouse reporting")] {
            check(view.beginFileDrop(pasteboard, sequence: 7), "shell accepts before \(name)")
            view.feed(text: enable)
            check(!view.finishFileDrop(pasteboard, sequence: 7) && !view.beginFileDrop(pasteboard, sequence: 8), "\(name) blocks pending/new drops")
            view.feed(text: disable)
        }
        check(view.beginFileDrop(pasteboard, sequence: 9), "shell accepts after mode restoration")
        check(!view.finishFileDrop(pasteboard, sequence: 10), "foreign drag sequence rejected")
        let nonFile = NSPasteboardItem()
        nonFile.setString("ordinary text", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([urls[0] as NSURL, nonFile])
        check(FileDropTerminalView.fileURLs(from: pasteboard) == nil, "mixed payload rejected as a whole")
        pasteboard.clearContents()
        pasteboard.setString("ordinary text", forType: .string)
        check(!view.beginFileDrop(pasteboard, sequence: 11), "text-only/internal drag not claimed")
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        check(view.beginFileDrop(pasteboard, sequence: 12), "valid drop before teardown")
        view.invalidateFileDrop()
        check(!view.finishFileDrop(pasteboard, sequence: 12), "teardown invalidates destination")
        view.insertDroppedFiles = nil
        window.contentView = nil
        print("\(passed) local terminal file drop tests passed, 0 failed")
    }
}
