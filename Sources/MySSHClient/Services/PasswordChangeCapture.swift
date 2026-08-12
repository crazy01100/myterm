import Foundation

enum PasswordChangeCaptureResult: Equatable {
    case none
    case started
    case verified(Data)
    case rejected
}

/// Recognizes the conservative password-change sequence used by `passwd` and
/// expired-password login flows. It captures only the two new-password inputs,
/// requires them to match, and releases the candidate only after an explicit
/// server success message. OTP, sudo and isolated "new password" prompts do
/// not arm this state machine.
struct PasswordChangeCapture {
    private enum State: Equatable {
        case idle
        case sawCurrentPassword
        case capturingNewPassword
        case awaitingConfirmation
        case capturingConfirmation
        case awaitingOutcome
    }

    private var state: State = .idle
    private var outputBuffer = ""
    private var inputCapture = LoginPasswordCapture()
    private var candidate: [UInt8] = []

    mutating func consumeOutput(_ bytes: ArraySlice<UInt8>) -> PasswordChangeCaptureResult {
        outputBuffer += String(decoding: bytes, as: UTF8.self)
        if outputBuffer.count > 4_096 {
            outputBuffer = String(outputBuffer.suffix(4_096))
        }
        let normalized = Self.normalized(outputBuffer)

        switch state {
        case .idle:
            guard Self.endsWithCurrentPasswordPrompt(normalized) else { return .none }
            state = .sawCurrentPassword
            return .started

        case .sawCurrentPassword:
            guard Self.endsWithNewPasswordPrompt(normalized) else { return .none }
            inputCapture.begin()
            state = .capturingNewPassword
            return .none

        case .capturingNewPassword, .capturingConfirmation:
            return .none

        case .awaitingConfirmation:
            if Self.containsFailure(normalized) {
                reset()
                return .rejected
            }
            guard Self.endsWithConfirmationPrompt(normalized) else { return .none }
            inputCapture.begin()
            state = .capturingConfirmation
            return .none

        case .awaitingOutcome:
            if Self.containsSuccess(normalized) {
                let verified = Data(candidate)
                reset()
                return .verified(verified)
            }
            if Self.containsFailure(normalized) {
                reset()
                return .rejected
            }
            // Some passwd implementations return to the new-password prompt
            // after a policy rejection without a separate failure line.
            if Self.endsWithNewPasswordPrompt(normalized) {
                clearCandidate()
                inputCapture.begin()
                state = .capturingNewPassword
                return .rejected
            }
            return .none
        }
    }

    mutating func consumeInput(_ bytes: ArraySlice<UInt8>) -> PasswordChangeCaptureResult {
        guard state == .capturingNewPassword || state == .capturingConfirmation else {
            return .none
        }

        switch inputCapture.consume(bytes) {
        case .none:
            return .none
        case .cancelled:
            reset()
            return .rejected
        case .submitted(let data):
            var data = data
            defer {
                if !data.isEmpty { data.resetBytes(in: data.indices) }
            }
            guard !data.isEmpty else {
                reset()
                return .rejected
            }
            if state == .capturingNewPassword {
                clearCandidate()
                candidate = Array(data)
                state = .awaitingConfirmation
                outputBuffer.removeAll(keepingCapacity: true)
                return .none
            }

            let confirmation = Array(data)
            let matches = Self.constantTimeEqual(candidate, confirmation)
            var mutableConfirmation = confirmation
            for index in mutableConfirmation.indices { mutableConfirmation[index] = 0 }
            guard matches else {
                reset()
                return .rejected
            }
            state = .awaitingOutcome
            outputBuffer.removeAll(keepingCapacity: true)
            return .none
        }
    }

    mutating func cancel() {
        reset()
    }

    private mutating func reset() {
        inputCapture.cancel()
        clearCandidate()
        outputBuffer.removeAll(keepingCapacity: false)
        state = .idle
    }

    private mutating func clearCandidate() {
        for index in candidate.indices { candidate[index] = 0 }
        candidate.removeAll(keepingCapacity: false)
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        var difference = UInt(lhs.count ^ rhs.count)
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= UInt(left ^ right)
        }
        return difference == 0
    }

    private static func normalized(_ value: String) -> String {
        removingTerminalEscapes(from: value)
            .replacingOccurrences(of: "\r", with: "\n")
            .lowercased()
    }

    private static func lastNonemptyLine(_ value: String) -> String {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func endsWithCurrentPasswordPrompt(_ value: String) -> Bool {
        let line = lastNonemptyLine(value)
        let markers = [
            "current password:", "current unix password:", "(current) unix password:",
            "old password:", "current password：", "目前密碼:", "目前密碼：",
            "当前密码:", "当前密码：", "舊密碼:", "舊密碼：", "旧密码:", "旧密码："
        ]
        return markers.contains(where: line.hasSuffix)
    }

    private static func endsWithNewPasswordPrompt(_ value: String) -> Bool {
        let line = lastNonemptyLine(value)
        guard !endsWithConfirmationPrompt(value) else { return false }
        let markers = [
            "new password:", "new unix password:", "enter new password:",
            "new password：", "新密碼:", "新密碼：", "新密码:", "新密码："
        ]
        return markers.contains(where: line.hasSuffix)
    }

    private static func endsWithConfirmationPrompt(_ value: String) -> Bool {
        let line = lastNonemptyLine(value)
        let markers = [
            "retype new password:", "repeat new password:", "confirm new password:",
            "verify new password:", "re-enter new password:", "new password again:",
            "再次輸入新密碼:", "再次輸入新密碼：", "再次输入新密码:", "再次输入新密码：",
            "確認新密碼:", "確認新密碼：", "确认新密码:", "确认新密码："
        ]
        return markers.contains(where: line.hasSuffix)
    }

    private static func containsSuccess(_ value: String) -> Bool {
        let markers = [
            "password updated successfully", "password changed successfully",
            "password successfully changed", "password has been changed",
            "all authentication tokens updated successfully",
            "密碼已成功更新", "密码已成功更新", "密碼修改成功", "密码修改成功"
        ]
        return markers.contains(where: value.contains)
    }

    private static func containsFailure(_ value: String) -> Bool {
        let markers = [
            "passwords do not match", "password mismatch", "password unchanged",
            "authentication token manipulation error", "password change failed",
            "密碼不相符", "密码不匹配", "密碼未變更", "密码未更改", "密碼修改失敗", "密码修改失败"
        ]
        return markers.contains(where: value.contains)
    }

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
                    let scalar = scalars[index].value
                    index += 1
                    if scalar >= 0x40 && scalar <= 0x7E { break }
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
