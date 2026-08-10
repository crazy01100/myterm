import Foundation

enum LoginPasswordCaptureResult: Equatable {
    case none
    case submitted(Data)
    case cancelled
}

/// Mirrors the small subset of canonical terminal editing that is useful at
/// an SSH password prompt. The bytes are never rendered or converted to a
/// String and are cleared as soon as an attempt is submitted or cancelled.
struct LoginPasswordCapture {
    private let maximumLength = 4_096
    private var secret: [UInt8] = []
    private(set) var isCapturing = false

    mutating func begin() {
        clearSecret()
        isCapturing = true
    }

    mutating func consume(_ bytes: ArraySlice<UInt8>) -> LoginPasswordCaptureResult {
        guard isCapturing else { return .none }
        for byte in bytes {
            switch byte {
            case 0x0A, 0x0D:
                let submitted = Data(secret)
                clearSecret()
                isCapturing = false
                return .submitted(submitted)
            case 0x03, 0x04: // Control-C / Control-D
                clearSecret()
                isCapturing = false
                return .cancelled
            case 0x08, 0x7F: // Backspace / Delete
                if !secret.isEmpty { secret.removeLast() }
            case 0x15: // Control-U
                clearSecret()
            case 0x17: // Control-W
                while secret.last == 0x20 { secret.removeLast() }
                while let last = secret.last, last != 0x20 { secret.removeLast() }
            default:
                guard secret.count < maximumLength else {
                    clearSecret()
                    isCapturing = false
                    return .cancelled
                }
                secret.append(byte)
            }
        }
        return .none
    }

    mutating func cancel() {
        clearSecret()
        isCapturing = false
    }

    private mutating func clearSecret() {
        for index in secret.indices { secret[index] = 0 }
        secret.removeAll(keepingCapacity: false)
    }
}

enum ObservedSSHAuthentication: Equatable {
    case password
    case other(String)
}

/// Parses OpenSSH's private `-v -E` diagnostic stream. MyTerm asks to save a
/// captured attempt only after this detector sees OpenSSH itself report that
/// authentication completed using the `password` method.
struct SSHAuthenticationLogDetector {
    private var buffer = ""
    private(set) var didResolveAuthentication = false

    mutating func consume(_ bytes: ArraySlice<UInt8>) -> ObservedSSHAuthentication? {
        guard !didResolveAuthentication else { return nil }
        buffer += String(decoding: bytes, as: UTF8.self)
        if buffer.count > 32_768 { buffer = String(buffer.suffix(32_768)) }

        let pattern = #"Authenticated to .* using \"([^\"]+)\"\."#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: buffer,
                range: NSRange(buffer.startIndex..., in: buffer)
              ),
              let methodRange = Range(match.range(at: 1), in: buffer) else {
            return nil
        }

        didResolveAuthentication = true
        let method = String(buffer[methodRange])
        buffer.removeAll(keepingCapacity: false)
        return method == "password" ? .password : .other(method)
    }
}
