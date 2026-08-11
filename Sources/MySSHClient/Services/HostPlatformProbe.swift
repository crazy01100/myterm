import Foundation

/// Identifies the remote platform over a short, separate, non-interactive SSH
/// command. This keeps probe output out of the user's terminal and never alters
/// the remote host. Passwords use the same FIFO-backed AskPass path as SFTP and
/// are never placed in arguments, environment variables, or regular files.
enum HostPlatformProbe {
    static func detect(
        host: HostProfile,
        username: String,
        timeout: TimeInterval = 9
    ) -> HostPlatform? {
        guard host.detectedPlatform == nil else { return host.detectedPlatform }

        do {
            var arguments = try SSHArgumentBuilder.arguments(
                for: host,
                usernameOverride: username
            )
            guard let destination = arguments.popLast() else { return nil }
            arguments += [
                "-o", "StrictHostKeyChecking=yes",
                "-o", "ConnectTimeout=6",
                "-o", "ConnectionAttempts=1",
                "-o", "NumberOfPasswordPrompts=1"
            ]
            if host.authenticationMethod != .password {
                arguments += ["-o", "BatchMode=yes"]
            }
            arguments += [destination, probeCommand]

            var environment = SSHEnvironmentBuilder.environmentDictionary()
            var passwordPipe: SSHPasswordPipe?
            if host.authenticationMethod == .password {
                guard let data = try KeychainStore.passwordData(for: host.id),
                      let password = String(data: data, encoding: .utf8) else { return nil }
                let pipe = try SSHPasswordPipe(password: password)
                passwordPipe = pipe
                environment["SSH_ASKPASS"] = pipe.askPassURL.path
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["DISPLAY"] = "myterm:0"
            }
            defer { passwordPipe?.cleanup() }

            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                return nil
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }
            var detector = HostPlatformDetector()
            return detector.consume(Array(data)[...])
        } catch {
            return nil
        }
    }

    private static let probeCommand = """
    LC_ALL=C; \
    cat /etc/os-release /usr/lib/os-release /etc/redhat-release /etc/alpine-release 2>/dev/null; \
    uname -a 2>/dev/null
    """
}
