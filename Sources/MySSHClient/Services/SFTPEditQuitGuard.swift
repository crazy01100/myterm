import AppKit

@MainActor
final class SFTPEditQuitGuard: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let edits = SFTPExternalEditStore.shared
        guard edits.needsQuitConfirmation else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "停止編輯回存並退出 MyTerm？"
        alert.informativeText = "尚有外部編輯工作或未確認回存的變更。退出會停止自動回存，本機副本會保留；重新開啟後需連線到原主機，再選擇恢復回存。編輯器不會被關閉。"
        alert.addButton(withTitle: "返回")
        alert.addButton(withTitle: "保留副本並退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        edits.pauseForQuit()
        return .terminateNow
    }
}
