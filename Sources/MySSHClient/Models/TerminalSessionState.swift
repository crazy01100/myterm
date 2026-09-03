import Foundation

enum SessionState: Equatable {
    case connecting
    case connected
    case disconnected(Int32?)
    case failed(String)

    var label: String {
        switch self {
        case .connecting: "連線中"
        case .connected: "已連線"
        case .disconnected(let code): code.map { "已中斷（\($0)）" } ?? "已中斷"
        case .failed(let message): message
        }
    }
}

enum TerminalSessionKind: Equatable {
    case ssh
    case local
    case serial
}

enum TerminalReconnectPolicy {
    static func canReconnect(
        kind: TerminalSessionKind,
        state: SessionState,
        processIsRunning: Bool
    ) -> Bool {
        guard kind == .ssh, !processIsRunning else { return false }
        return switch state {
        case .disconnected, .failed: true
        case .connecting, .connected: false
        }
    }

    static func isReturnInput(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.count == 1 && (bytes.first == 0x0D || bytes.first == 0x0A)
    }
}

enum TerminalReconnectPresentationPolicy {
    static func resetModes(isAlternateBuffer: Bool) -> [UInt8] {
        var sequence = "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?1015l\u{1B}[?2004l"
        if isAlternateBuffer {
            sequence += "\u{1B}[?1049l"
        }
        return Array(sequence.utf8)
    }

    static func bottomRow(for rowCount: Int) -> Int {
        max(0, rowCount - 1)
    }
}
