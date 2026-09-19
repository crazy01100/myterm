import Foundation

enum SSHArgumentBuilder {
    static func arguments(
        for host: HostProfile,
        usernameOverride: String? = nil,
        connectionLogURL: URL? = nil
    ) throws -> [String] {
        let host = try host.validated()
        let username = try HostProfile.validatedUsername(usernameOverride ?? host.username)
        try AppPaths.prepare()

        // UserKnownHostsFile is a whitespace-separated list parsed by OpenSSH,
        // even when the complete `-o` value is already one process argument.
        // Quote each path separately so macOS' "Application Support" directory
        // is not mistaken for multiple known-host files.
        let trustedHostFiles = [AppPaths.knownHostsFile.path, AppPaths.importedKnownHostsRawFile.path]
            .map(quotedSSHConfigurationValue)
            .joined(separator: " ")

        var arguments = [
            "-p", String(host.port),
            "-o", "UserKnownHostsFile=\(trustedHostFiles)",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "HashKnownHosts=yes",
            "-o", "UpdateHostKeys=yes",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3"
        ]

        switch host.authenticationMethod {
        case .password:
            arguments += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no"
            ]
        case .privateKey:
            arguments += [
                "-o", "PreferredAuthentications=publickey",
                "-o", "IdentitiesOnly=yes",
                "-i", host.privateKeyPath
            ]
        case .sshAgent:
            break
        }

        switch host.algorithmMode {
        case .systemDefault:
            break
        case .rsaCompatibility:
            arguments += [
                "-o", "HostKeyAlgorithms=+ssh-rsa",
                "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa"
            ]
        case .custom:
            appendOption("HostKeyAlgorithms", value: host.customAlgorithms.hostKeyAlgorithms, to: &arguments)
            appendOption("PubkeyAcceptedAlgorithms", value: host.customAlgorithms.publicKeyAlgorithms, to: &arguments)
            appendOption("KexAlgorithms", value: host.customAlgorithms.keyExchangeAlgorithms, to: &arguments)
            appendOption("Ciphers", value: host.customAlgorithms.ciphers, to: &arguments)
        }

        if let connectionLogURL {
            arguments += ["-v", "-E", connectionLogURL.path]
        }

        // Brackets disambiguate IPv6 in forms, but ssh's hostname argument
        // expects the literal without brackets (unlike an scp URI).
        let hostname = host.hostname.hasPrefix("[") && host.hostname.hasSuffix("]")
            ? String(host.hostname.dropFirst().dropLast()) : host.hostname
        arguments.append("\(username)@\(hostname)")
        return arguments
    }

    private static func appendOption(_ name: String, value: String, to arguments: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { arguments += ["-o", "\(name)=\(trimmed)"] }
    }

    private static func quotedSSHConfigurationValue(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

enum SSHEnvironmentBuilder {
    /// Passes only the environment needed by an interactive OpenSSH process.
    /// In particular, SSH_AUTH_SOCK is required for the SSH Agent authentication mode.
    static func environment(from source: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var result = [
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "LANG=\(source["LANG"] ?? "en_US.UTF-8")"
        ]
        let allowedKeys = ["USER", "LOGNAME", "HOME", "PATH", "LC_CTYPE", "SSH_AUTH_SOCK"]
        for key in allowedKeys {
            if let value = source[key], !value.contains("\n"), !value.contains("\0") {
                result.append("\(key)=\(value)")
            }
        }
        return result
    }
}

enum LocalTerminalEnvironmentBuilder {
    /// Uses a fixed system shell path and the same allow-listed environment as SSH.
    static func environment(from source: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var result = SSHEnvironmentBuilder.environment(from: source)
        result.append("SHELL=/bin/zsh")
        return result
    }

    /// A GUI app can inherit `/` as its process working directory. Local shells
    /// should instead begin where a user expects an interactive Terminal to begin.
    static func currentDirectory(fileManager: FileManager = .default) -> String {
        fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
    }
}
