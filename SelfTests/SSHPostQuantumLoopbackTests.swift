import Foundation
import Darwin

@main struct SSHPostQuantumLoopbackTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MYTERM_PQ_TEST_DIRECTORY"]!)
        let port = Int(CommandLine.arguments[1])!
        let username = CommandLine.arguments[2]
        let mode = CommandLine.arguments[3]
        var host = HostProfile()
        host.hostname = "127.0.0.1"; host.port = port; host.username = username
        host.authenticationMethod = .privateKey; host.privateKeyPath = root.appendingPathComponent("client").path
        if mode != "classical" { host = try SSHPostQuantumPolicy.settingRequired(true, for: host) }
        let capabilities = await SSHCapabilityService.shared.query(forceRefresh: true).capabilities
        let stream = try SSHDiagnosticStream(requiresPostQuantum: mode != "classical")
        defer { stream.close() }
        var args = try SSHArgumentBuilder.arguments(for: host, connectionLogURL: stream.url, capabilities: capabilities)
        let destination = args.removeLast()
        args += ["-o", "BatchMode=yes", "-o", "RekeyLimit=16K", "-F", "/dev/null"]
        if mode == "sftp" { args += ["-s", destination, "sftp"] }
        else { args += [destination, "dd if=/dev/zero bs=4096 count=32 2>/dev/null; sleep 0.3"] }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.standardInput = input
        process.standardOutput = mode == "sftp" ? output : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        if mode == "sftp" {
            try input.fileHandleForWriting.write(contentsOf: Data([0,0,0,5,1,0,0,0,3]))
            let fd = output.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        }
        var observed = Set<String>(), records = "", sftpReply = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var inputClosed = false
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            let snapshot = stream.snapshot()
            records += String(decoding: snapshot.bytes, as: UTF8.self)
            precondition(records.utf8.count < 200000)
            if snapshot.protection.status == .postQuantum { observed.insert("pq") }
            if snapshot.protection.status == .traditional { observed.insert("classical") }
            if mode == "sftp" {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let n = read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                if n > 0 { sftpReply.append(contentsOf: bytes.prefix(n)) }
                if sftpReply.count >= 9, !inputClosed, observed.contains("pq") {
                    try input.fileHandleForWriting.close(); inputClosed = true
                }
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(!process.isRunning, "Loopback timed out")
        let final = stream.snapshot()
        records += String(decoding: final.bytes, as: UTF8.self)
        if mode == "reject" {
            precondition(process.terminationStatus != 0 && observed.isEmpty, "Strict mode unexpectedly connected")
            var parser = SSHConnectionLogParser(requiresPostQuantum: true)
            let events = parser.consume(Array(records.utf8)[...]).events
            precondition(events.contains { $0.message == "遠端主機未提供相容的後量子金鑰交換" }, "Missing real mismatch explanation")
            precondition(!events.contains { $0.phase == .authenticating || $0.phase == .connected }, "Real rejected handshake claims authentication")
            precondition(final.failureMessage.contains("遠端主機未提供相容的後量子金鑰交換"), "SFTP-style error lost mismatch explanation")
        } else {
            // Output only a sanitized failure category; raw diagnostics stay in memory.
            if process.terminationStatus != 0 {
                let reason = records.contains("Permission denied") ? "authentication rejected" : records.contains("Host key verification failed") ? "host key rejected" : "connection failed"
                fatalError("Loopback \(reason): \(final.failureMessage)")
            }
            precondition(observed.contains(mode == "classical" ? "classical" : "pq"), "Actual negotiated status not observed")
            if mode == "sftp" { precondition(sftpReply.count >= 9 && sftpReply[4] == 2, "Not SFTP VERSION response") }
            else { precondition(records.components(separatedBy: "debug1: kex: algorithm:").count >= 3, "No real rekey observed") }
        }
        print("Loopback \(mode): passed; SSH exit \(process.terminationStatus); KEX observations \(records.components(separatedBy: "debug1: kex: algorithm:").count - 1)")
    }
}
