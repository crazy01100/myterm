import Foundation

struct SSHNegotiatedProtection: Equatable, Sendable {
    enum Status: Sendable { case negotiating, postQuantum, traditional, unknown, closed }
    var status: Status = .negotiating
    var algorithm: String?
    var title: String {
        switch status {
        case .negotiating: "協商中"
        case .postQuantum: "後量子金鑰交換"
        case .traditional: "傳統金鑰交換"
        case .unknown: "無法確認金鑰交換"
        case .closed: "連線已結束"
        }
    }
}

/// Consumes only the local OpenSSH diagnostic channel, never terminal output.
struct SSHProtectionParser {
    private var partial = Data()
    private var authenticated = false
    private var sent = false
    private var received = false
    private var exchangeStarted = false
    private var observationLost = false
    private(set) var value = SSHNegotiatedProtection()

    mutating func loseObservation() {
        observationLost = true
        partial.removeAll()
        value = SSHNegotiatedProtection(status: .unknown)
    }

    mutating func consume(_ bytes: Data) {
        guard !observationLost else { return }
        for byte in bytes {
            guard !observationLost else { return }
            if byte == 10 {
                let line = String(decoding: partial, as: UTF8.self).trimmingCharacters(in: .newlines)
                partial.removeAll(keepingCapacity: true)
                consumeLine(line)
            } else {
                guard partial.count < 8192 else { loseObservation(); return }
                partial.append(byte)
            }
        }
    }

    private mutating func consumeLine(_ original: String) {
        let line = original.hasPrefix("debug1: ") ? String(original.dropFirst(8)) : original
        if original == "debug1: SSH2_MSG_KEXINIT sent" || original == "debug1: SSH2_MSG_KEXINIT received" {
            sent = false; received = false
            exchangeStarted = true
            value = SSHNegotiatedProtection()
        } else if original.hasPrefix("debug1: kex: algorithm: ") {
            let name = String(original.dropFirst("debug1: kex: algorithm: ".count))
            guard name.count <= 256, !name.isEmpty,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "@._-".contains($0)) }) else {
                loseObservation(); return
            }
            value.algorithm = name
            exchangeStarted = true
        } else if original == "debug1: SSH2_MSG_NEWKEYS sent" { sent = true }
        else if original == "debug1: SSH2_MSG_NEWKEYS received" { received = true }
        else if line.hasPrefix("Authenticated to ") || line.hasPrefix("Authentication succeeded (") { authenticated = true }
        else if original.hasPrefix("debug1: auto-mux:") || original.hasPrefix("debug1: mux_client_request_session:") {
            loseObservation(); return
        }
        guard authenticated else { return }
        guard let algorithm = value.algorithm, sent, received else { value.status = exchangeStarted ? .negotiating : .unknown; return }
        if SSHPostQuantumPolicy.recognizedAlgorithms.contains(algorithm) { value.status = .postQuantum }
        else if Self.classicalAlgorithms.contains(algorithm) { value.status = .traditional }
        else { value.status = .unknown }
    }

    private static let classicalAlgorithms: Set<String> = [
        "curve25519-sha256", "curve25519-sha256@libssh.org",
        "ecdh-sha2-nistp256", "ecdh-sha2-nistp384", "ecdh-sha2-nistp521",
        "diffie-hellman-group1-sha1", "diffie-hellman-group14-sha1", "diffie-hellman-group14-sha256",
        "diffie-hellman-group16-sha512", "diffie-hellman-group18-sha512",
        "diffie-hellman-group-exchange-sha1", "diffie-hellman-group-exchange-sha256"
    ]
}
