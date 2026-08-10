import Foundation

struct LoginPasswordPromptDetector {
    private var promptBuffer = ""
    private(set) var didHandlePasswordPrompt = false

    mutating func consume(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard !didHandlePasswordPrompt else { return false }
        promptBuffer += String(decoding: bytes, as: UTF8.self)
        if promptBuffer.count > 1_024 { promptBuffer = String(promptBuffer.suffix(1_024)) }
        guard promptBuffer.lowercased().contains("password:") else { return false }
        didHandlePasswordPrompt = true
        promptBuffer.removeAll(keepingCapacity: false)
        return true
    }
}

/// Tracks whether the visible output currently ends at a reusable password
/// prompt. This is deliberately separate from login automation: it remains
/// active after SSH login so manual Keychain insertion can be gated for sudo,
/// su and device prompts as well.
struct PasswordPromptStateDetector {
    private var currentLine = ""
    private(set) var isAwaitingPassword = false

    /// Returns a state only when it changes.
    mutating func consume(_ bytes: ArraySlice<UInt8>) -> Bool? {
        for character in String(decoding: bytes, as: UTF8.self) {
            switch character {
            case "\n", "\r":
                currentLine.removeAll(keepingCapacity: true)
            case "\u{8}":
                if !currentLine.isEmpty { currentLine.removeLast() }
            default:
                currentLine.append(character)
                if currentLine.count > 1_024 {
                    currentLine = String(currentLine.suffix(1_024))
                }
            }
        }

        let newState = Self.matchesPasswordPrompt(Self.removingTerminalEscapes(from: currentLine))
        guard newState != isAwaitingPassword else { return nil }
        isAwaitingPassword = newState
        return newState
    }

    mutating func userDidSendInput() -> Bool? {
        currentLine.removeAll(keepingCapacity: false)
        guard isAwaitingPassword else { return nil }
        isAwaitingPassword = false
        return false
    }

    private static func matchesPasswordPrompt(_ line: String) -> Bool {
        let normalized = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let unsafePromptMarkers = [
            "new password", "retype", "repeat password", "confirm password", "verification code", "otp",
            "新密碼", "新密码", "確認密碼", "确认密码", "再次輸入", "再次输入", "驗證碼", "验证码"
        ]
        guard !unsafePromptMarkers.contains(where: normalized.contains) else { return false }

        let endsWithColon = normalized.hasSuffix(":") || normalized.hasSuffix("：")
        return normalized.hasSuffix("password:")
            || normalized.hasSuffix("password：")
            || (endsWithColon && normalized.contains("password for "))
            || normalized.hasSuffix("的密碼:")
            || normalized.hasSuffix("的密碼：")
            || normalized.hasSuffix("的密码:")
            || normalized.hasSuffix("的密码：")
            || normalized == "密碼:"
            || normalized == "密碼："
            || normalized == "密码:"
            || normalized == "密码："
    }

    /// Removes CSI/OSC terminal control sequences before matching the visible
    /// end of the line. Keeping the raw line allows sequences split over PTY
    /// reads to be handled on the next call.
    private static func removingTerminalEscapes(from value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index].value == 0x1B else {
                result.append(scalars[index])
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { break }
            if scalars[index] == "[" {
                index += 1
                while index < scalars.count {
                    let value = scalars[index].value
                    index += 1
                    if value >= 0x40 && value <= 0x7E { break }
                }
            } else if scalars[index] == "]" {
                index += 1
                while index < scalars.count {
                    if scalars[index].value == 0x07 {
                        index += 1
                        break
                    }
                    if scalars[index].value == 0x1B,
                       index + 1 < scalars.count,
                       scalars[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return String(result)
    }
}
