import Darwin
import Foundation

/// Parsed connection data, never shell source. UI requests come from the parser;
/// creating a temporary profile validates the endpoint again at use.
struct QuickSSHRequest: Hashable {
    let username: String
    /// IPv6 keeps brackets for HostProfile validation / human-readable display.
    let hostname: String
    let port: Int

    var displayAddress: String { "\(username)@\(hostname):\(port)" }

    static func parse(_ input: String) -> Self? {
        guard input.utf8.count <= 400,
              input.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.contains(where: { $0.isWhitespace }) else { return nil }
        let pieces = text.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let user = String(pieces[0]), address = String(pieces[1])
        guard !user.hasPrefix("-"), (try? HostProfile.validatedUsername(user)) != nil else { return nil }
        let rawHost: String, rawPort: String?
        if address.hasPrefix("[") {
            guard let end = address.firstIndex(of: "]") else { return nil }
            rawHost = String(address[...end])
            let suffix = address[address.index(after: end)...]
            guard suffix.isEmpty || suffix.hasPrefix(":") else { return nil }
            rawPort = suffix.isEmpty ? nil : String(suffix.dropFirst())
        } else {
            let split = address.split(separator: ":", omittingEmptySubsequences: false)
            guard split.count == 1 || split.count == 2 else { return nil }
            rawHost = String(split[0])
            rawPort = split.count == 2 ? String(split[1]) : nil
        }
        let port: Int
        if let rawPort {
            guard !rawPort.isEmpty, rawPort.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(rawPort), (1...65535).contains(number) else { return nil }
            port = number
        } else { port = 22 }
        guard let hostname = normalizedHost(rawHost) else { return nil }
        var host = HostProfile()
        host.hostname = hostname; host.username = user; host.port = port
        guard (try? host.validated()) != nil else { return nil }
        return Self(username: user, hostname: hostname, port: port)
    }

    static func forEndpoint(username: String, hostname: String, port: Int) -> Self? {
        parse("\(username)@\(hostname):\(port)")
    }

    func temporaryProfile() throws -> HostProfile {
        var host = HostProfile()
        host.hostname = hostname
        host.username = username
        host.port = port
        host.authenticationMethod = .sshAgent
        return try host.validated()
    }

    private static func normalizedHost(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            var address = in6_addr()
            let inner = String(raw.dropFirst().dropLast())
            guard inner.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            var canonical = String(cString: buffer)
            // HostProfile uses a hexadecimal-only bracketed IPv6 form.
            if let lastColon = canonical.lastIndex(of: ":"), canonical.contains(".") {
                let octets = canonical[canonical.index(after: lastColon)...].split(separator: ".").compactMap { UInt16($0) }
                guard octets.count == 4 else { return nil }
                canonical = String(canonical[...lastColon])
                    + String(octets[0] * 256 + octets[1], radix: 16) + ":"
                    + String(octets[2] * 256 + octets[3], radix: 16)
            }
            return "[\(canonical)]"
        }
        if raw.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            var address = in_addr()
            guard raw.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
            return raw
        }
        guard raw.utf8.count <= 253 else { return nil }
        let domain = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }) else { return nil }
        return raw.lowercased()
    }
}

enum SSHSessionOrigin {
    case savedHost, temporary

    func permitsPasswordBinding(host: HostProfile, username: String) -> Bool {
        self == .savedHost && host.authenticationMethod == .password
            && !host.username.isEmpty && username == host.username
    }
}
