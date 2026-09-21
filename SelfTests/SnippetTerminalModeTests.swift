import AppKit
import SwiftTerm

@main
struct SnippetTerminalModeTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var passed = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError("FAIL: \(message)") }
            passed += 1
            print("PASS: \(message)")
        }
        let view = SnippetGuardedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let other = SnippetGuardedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = view.getTerminal()
        check(view.allowsSnippetInTerminalMode, "ordinary shell allows insertion")
        // Readline/zle can use application-cursor and bracketed-paste modes;
        // neither alone proves that a fullscreen application owns the input.
        view.feed(text: "\u{1b}[?1h\u{1b}=\u{1b}[?2004h$ ")
        check(view.allowsSnippetInTerminalMode, "shell application keys and bracketed paste do not cause a false block")
        view.feed(text: "\u{1b}[?25l\u{1b}[H\u{1b}[2Jsynthetic monitor")
        check(!terminal.isCurrentBufferAlternate, "top-style fixture stays in the normal buffer")
        check(!view.allowsSnippetInTerminalMode, "hidden cursor on normal screen blocks before visual dispatch")
        check(other.allowsSnippetInTerminalMode, "another pane remains independent")
        view.feed(text: "\u{1b}[Hsynthetic refresh\r\n")
        check(!view.allowsSnippetInTerminalMode, "redraws and newlines do not release hidden-cursor guard")
        view.feed(text: "\u{1b}[?25")
        check(!view.allowsSnippetInTerminalMode, "split cursor-restoration sequence stays blocked until complete")
        view.feed(text: "h\u{1b}[?1l\u{1b}>$ ")
        check(view.allowsSnippetInTerminalMode, "normal-screen exit restores insertion immediately")
        view.feed(text: "\u{1b}[?1049h\u{1b}[?25h")
        check(!view.allowsSnippetInTerminalMode, "alternate-screen editor blocks even with visible cursor")
        view.feed(text: "\u{1b}[?1049l")
        check(view.allowsSnippetInTerminalMode, "leaving alternate screen restores shell")
        view.feed(text: "\u{1b}[?1000h")
        check(!view.allowsSnippetInTerminalMode, "normal-screen mouse reporting blocks insertion")
        view.feed(text: "\u{1b}[?1000l")
        check(view.allowsSnippetInTerminalMode, "leaving mouse reporting restores insertion")
        view.feed(text: "\u{1b}[?25l")
        check(!view.allowsSnippetInTerminalMode, "hidden shell cursor conservatively blocks regardless of displayed text")
        terminal.softReset()
        check(view.allowsSnippetInTerminalMode, "reconnect soft reset restores cursor guard")
        view.feed(text: "\u{1b}[?25l\u{1b}[?25h\u{1b}[?25l")
        check(!view.allowsSnippetInTerminalMode, "last hide wins in a coalesced output batch")
        view.feed(text: "\u{1b}[?25h")
        check(view.allowsSnippetInTerminalMode, "last show restores without waiting for caret rendering")
        view.feed(text: "top vim password are ordinary output here\r\n")
        check(view.allowsSnippetInTerminalMode, "terminal-mode guard does not guess from command names")
        print("\(passed) snippet terminal mode tests passed, 0 failed")
    }
}
