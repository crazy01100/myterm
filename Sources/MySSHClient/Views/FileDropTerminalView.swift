import AppKit
import SwiftTerm

/// A destination on the terminal itself, not an overlay on the workspace.
/// Only local sessions install these callbacks and register for file URLs.
class FileDropTerminalView: SnippetGuardedTerminalView {
    var fileDropTarget: (() -> LocalTerminalFileDropTarget?)?
    var insertDroppedFiles: (([URL], LocalTerminalFileDropTarget) -> Bool)?
    var fileDropVisible = false
    private var pendingDrop: (sequence: Int, target: LocalTerminalFileDropTarget)?

    func sendDroppedPathText(_ text: String) {
        let bytes = LocalTerminalFileDrop.bytes(for: text, bracketedPaste: getTerminal().bracketedPasteMode)
        send(source: self, data: bytes[...])
    }

    func invalidateFileDrop() {
        pendingDrop = nil
        fileDropTarget = nil
        insertDroppedFiles = nil
        unregisterDraggedTypes()
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty,
              items.count <= LocalTerminalFileDrop.maximumItems else { return nil }
        var urls: [URL] = []
        for item in items {
            guard let value = item.string(forType: .fileURL),
                  value.utf8.count <= LocalTerminalFileDrop.maximumBytes * 3,
                  let url = URL(string: value), url.isFileURL else { return nil }
            urls.append(url)
        }
        guard LocalTerminalFileDrop.text(for: urls) != nil else { return nil }
        return urls
    }

    private var currentFileDropTarget: LocalTerminalFileDropTarget? {
        guard fileDropVisible, window != nil, !isHiddenOrHasHiddenAncestor,
              window?.attachedSheet == nil, NSApp.modalWindow == nil else { return nil }
        return fileDropTarget?()
    }

    // Shared by the AppKit entry points and isolated pasteboard/lifecycle tests.
    func beginFileDrop(_ pasteboard: NSPasteboard, sequence: Int) -> Bool {
        pendingDrop = nil
        guard let target = currentFileDropTarget, Self.fileURLs(from: pasteboard) != nil else { return false }
        pendingDrop = (sequence, target)
        return true
    }

    func acceptsFileDrop(_ pasteboard: NSPasteboard, sequence: Int) -> Bool {
        guard let pendingDrop, pendingDrop.sequence == sequence,
              currentFileDropTarget == pendingDrop.target,
              Self.fileURLs(from: pasteboard) != nil else { return false }
        return true
    }

    func finishFileDrop(_ pasteboard: NSPasteboard, sequence: Int) -> Bool {
        defer { pendingDrop = nil }
        guard acceptsFileDrop(pasteboard, sequence: sequence), let pendingDrop,
              let urls = Self.fileURLs(from: pasteboard) else { return false }
        return insertDroppedFiles?(urls, pendingDrop.target) == true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSourceOperationMask.contains(.copy),
              beginFileDrop(sender.draggingPasteboard, sequence: sender.draggingSequenceNumber) else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSourceOperationMask.contains(.copy)
            && acceptsFileDrop(sender.draggingPasteboard, sequence: sender.draggingSequenceNumber) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSourceOperationMask.contains(.copy)
            && acceptsFileDrop(sender.draggingPasteboard, sequence: sender.draggingSequenceNumber)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSourceOperationMask.contains(.copy) else { pendingDrop = nil; return false }
        return finishFileDrop(sender.draggingPasteboard, sequence: sender.draggingSequenceNumber)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { pendingDrop = nil }
    override func draggingEnded(_ sender: NSDraggingInfo) { pendingDrop = nil }
}
