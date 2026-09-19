import Foundation
import Darwin

@main struct SFTPSecurityTests {
    static var passed = 0
    static var failed = 0
    static func check(_ ok: Bool, _ name: String) {
        if ok { passed += 1; print("PASS: \(name)") }
        else { failed += 1; print("FAIL: \(name)") }
    }
    static func expected(_ error: Error, mode: String) -> Bool {
        let protocolErrors: [String: SFTPProtocolError] = [
            "name_limit": .resourceLimit, "depth": .resourceLimit,
            "status_ok": .unexpectedPacket(SFTPPacketType.status),
            "empty_data": .malformedPacket, "long_data": .malformedPacket,
            "empty_name": .malformedPacket,
            "oversized": .packetTooLarge(SFTPProtocolCodec.maximumPacketSize + 1)
        ]
        if let expected = protocolErrors[mode] { return (error as? SFTPProtocolError) == expected }
        guard let connectionError = error as? SFTPConnectionError else { return false }
        switch (mode, connectionError) {
        case ("init_stall", .timedOut), ("partial", .timedOut),
             ("realpath_stall", .cancelled), ("list_stall", .cancelled),
             ("early_exit", .connectionClosed): return true
        default: return false
        }
    }
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              CommandLine.arguments[2].hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: CommandLine.arguments[2]) else {
            fputs("Use scripts/run-sftp-security-tests.sh with its validated Python runtime.\n", stderr)
            exit(64)
        }
        let pythonURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyTerm-SFTP-security-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = CommandLine.arguments[1]
        for mode in ["name_limit", "status_ok", "empty_data", "long_data", "empty_name", "depth", "init_stall", "partial", "oversized", "early_exit", "realpath_stall", "list_stall", "slow"] {
            let output = root.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let pidFile = output.appendingPathComponent("peer.pid")
            let cancellation = SFTPCancellation()
            let start = ProcessInfo.processInfo.systemUptime
            if mode == "realpath_stall" || mode == "list_stall" {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancellation.cancel() }
            }
            do {
                let client = try SFTPClient.connectForTesting(
                    executableURL: pythonURL,
                    arguments: [peer, mode, pidFile.path], cancellation: cancellation,
                    responseTimeout: 0.5, initializationTimeout: 0.5
                )
                defer { client.close() }
                if mode == "name_limit" || mode == "empty_name" || mode == "list_stall" {
                    _ = try client.listDirectory("/test")
                } else if mode == "realpath_stall" {
                    _ = try client.realPath(".")
                } else {
                    client.completeInitialization()
                    let attrs = SFTPFileAttributes(permissions: mode == "depth" ? 0o40755 : 0o100644)
                    let entry = SFTPDirectoryEntry(name: "download", longName: "", attributes: attrs)
                    try client.downloadItem(entry, from: "/test", to: output) { _, _ in }
                    if mode == "slow" {
                        let data = try Data(contentsOf: output.appendingPathComponent("download"))
                        check(data == Data(String(repeating: "12345678", count: 8).utf8), "slow transfer preserves bytes")
                    }
                }
                check(mode == "slow", "\(mode) expected outcome")
            } catch {
                check(expected(error, mode: mode), "\(mode) rejects with the expected error: \(error)")
            }
            check(ProcessInfo.processInfo.systemUptime - start < 3, "\(mode) operation is bounded")
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) {
                for _ in 0..<30 {
                    if Darwin.kill(pid, 0) != 0 { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                check(Darwin.kill(pid, 0) != 0, "\(mode) child process exits")
            } else {
                check(false, "\(mode) fake peer did not record its startup PID")
            }
        }
        let cancellation = SFTPCancellation()
        cancellation.cancel()
        do {
            _ = try SFTPClient.connectForTesting(executableURL: pythonURL, arguments: [peer, "init_stall"], cancellation: cancellation)
            check(false, "pre-cancelled connection")
        } catch { check(true, "pre-cancelled connection") }
        print("\(passed) SFTP security tests passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
