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

enum TerminalSelectionInteractionPolicy {
    static func shouldClearLocalSelectionOnLinefeed(
        remoteMouseReportingActive: Bool
    ) -> Bool {
        remoteMouseReportingActive
    }
}

enum TerminalMouseWheelReportPolicy {
    static let coalescingDelay: TimeInterval = 0.016
    static let responseCoalescingWindow: TimeInterval = 0.100
    static let responseBufferLimit = 128 * 1024
    static let pacedScrollBacklogLimit = 24

    static func isMouseWheelReport(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4, bytes[0] == 0x1B, bytes[1] == 0x5B else {
            return false
        }

        if bytes[2] == UInt8(ascii: "M") {
            return isWheelButton(Int(bytes[3]) - 32)
        }

        var index = 2
        if bytes[index] == UInt8(ascii: "<") {
            index += 1
        }
        let start = index
        while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
            index += 1
        }
        guard index > start, index < bytes.count, bytes[index] == UInt8(ascii: ";"),
              let flags = Int(String(decoding: bytes[start..<index], as: UTF8.self)) else {
            return false
        }

        let normalizedFlags = flags >= 96 ? flags - 32 : flags
        return isWheelButton(normalizedFlags)
    }

    private static func isWheelButton(_ flags: Int) -> Bool {
        let baseButton = flags & ~(4 | 8 | 16)
        return baseButton == 64 || baseButton == 65
    }

    static func alternateBufferArrowSequence(
        scrollingUp: Bool,
        applicationCursor: Bool
    ) -> [UInt8] {
        if applicationCursor {
            return scrollingUp ? [0x1B, 0x4F, 0x41] : [0x1B, 0x4F, 0x42]
        }
        return scrollingUp ? [0x1B, 0x5B, 0x41] : [0x1B, 0x5B, 0x42]
    }

    static func accumulatePacedScrollSteps(current: Int, adding: Int) -> Int {
        min(pacedScrollBacklogLimit, max(-pacedScrollBacklogLimit, current + adding))
    }

    static func consumePacedScrollStep(_ pending: Int) -> (step: Int, remaining: Int) {
        if pending > 0 {
            return (1, pending - 1)
        }
        if pending < 0 {
            return (-1, pending + 1)
        }
        return (0, 0)
    }
}
