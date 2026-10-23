import Foundation

struct LocalTerminalFileDropTarget: Equatable {
    let sessionID: UUID
    let attemptID: UUID
}

enum LocalTerminalFileDrop {
    static let maximumItems = 256
    static let maximumBytes = 16_384

    // Treat each path as one literal shell argument, never as shell syntax.
    // Do not resolve symlinks or read the file: the user dropped this exact path.
    static func text(for urls: [URL]) -> String? {
        guard !urls.isEmpty, urls.count <= maximumItems else { return nil }
        var arguments: [String] = []
        var byteCount = 0
        for url in urls {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil else { return nil }
            let path = url.path
            guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
            }) else { return nil }
            let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            byteCount += quoted.utf8.count + (arguments.isEmpty ? 0 : 1)
            guard byteCount <= maximumBytes else { return nil }
            arguments.append(quoted)
        }
        return arguments.joined(separator: " ")
    }

    static func bytes(for text: String, bracketedPaste: Bool) -> [UInt8] {
        Array((bracketedPaste ? "\u{1b}[200~" + text + "\u{1b}[201~" : text).utf8)
    }
}
