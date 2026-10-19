import Foundation

@main struct SSHPostQuantumTests {
    static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        func reject(_ error: SSHPostQuantumError, _ work: () throws -> Void) {
            do { try work(); preconditionFailure("Expected rejection") }
            catch let received as SSHPostQuantumError { expect(received == error, "Wrong error") }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
        let mismatch = "Unable to negotiate with 192.0.2.1 port 22: no matching key exchange method found. Their offer: curve25519-sha256\n"
        var strictDiagnostics = SSHConnectionLogParser(requiresPostQuantum: true)
        let early = strictDiagnostics.consume(Array("debug1: Authenticating to fixture.invalid:22 as 'fixture'\n".utf8)[...])
        expect(early.events.allSatisfy { $0.phase == .securing && !$0.message.contains("已建立") }, "Early identity line claims established channel")
        let failed = strictDiagnostics.consume(Array(mismatch.utf8)[...])
        expect(failed.failure == .keyExchangeAlgorithm, "Failure code changed")
        expect(failed.events.contains { $0.message == "遠端主機未提供相容的後量子金鑰交換" }, "Missing strict failure explanation")
        expect(!failed.events.contains { $0.phase == .authenticating || $0.phase == .connected }, "Failed KEX advances to authentication")
        var ordinaryDiagnostics = SSHConnectionLogParser()
        expect(ordinaryDiagnostics.consume(Array(mismatch.utf8)[...]).events.first?.message == SSHConnectionFailureKind.keyExchangeAlgorithm.title, "Ordinary failure changed")
        var keysDiagnostics = SSHConnectionLogParser()
        expect(keysDiagnostics.consume(Array("debug1: SSH2_MSG_NEWKEYS sent\n".utf8)[...]).events.isEmpty, "One direction claims established channel")
        expect(keysDiagnostics.consume(Array("debug1: SSH2_MSG_NEWKEYS rece".utf8)[...]).events.isEmpty, "Partial marker claims established channel")
        let completedKeys = keysDiagnostics.consume(Array("ived\n".utf8)[...])
        expect(completedKeys.events.count == 1 && completedKeys.events[0].phase == .authenticating && completedKeys.events[0].message.contains("已建立"), "Bidirectional NEWKEYS not recognized")
        var retryDiagnostics = SSHConnectionLogParser()
        expect(retryDiagnostics.consume(Array("debug1: SSH2_MSG_NEWKEYS received\n".utf8)[...]).events.isEmpty, "New parser inherits previous keys")
        for kind: SSHConnectionFailureKind in [.timeout, .authenticationRejected, .hostKeyAlgorithm, .cipherAlgorithm, .hostKeyVerification] {
            expect(kind.title(requiringPostQuantum: true) == kind.title && kind.recoverySuggestion(requiringPostQuantum: true) == kind.recoverySuggestion, "Unrelated error changed under strict mode")
        }
        expect(SSHConnectionFailureKind.keyExchangeAlgorithm.recoverySuggestion(requiringPostQuantum: true).contains("已依這台主機的設定停止連線"), "Missing enforcement explanation")
        let failureStream = try SSHDiagnosticStream(requiresPostQuantum: true)
        let failureWriter = try FileHandle(forWritingTo: failureStream.url)
        try failureWriter.write(contentsOf: Data(mismatch.utf8))
        expect(failureStream.snapshot().failureMessage.contains("遠端主機未提供相容的後量子金鑰交換"), "SFTP failure stream loses contextual message")
        try failureWriter.close()
        failureStream.close()
        let begin = "debug1: SSH2_MSG_KEXINIT sent\ndebug1: SSH2_MSG_KEXINIT received\n"
        let selected = "debug1: kex: algorithm: mlkem768x25519-sha256\n"
        let keys = "debug1: SSH2_MSG_NEWKEYS sent\ndebug1: SSH2_MSG_NEWKEYS received\n"
        let authenticated = "Authenticated to fixture.invalid ([127.0.0.1]:22) using \"publickey\".\n"
        var parser = SSHProtectionParser()
        parser.consume(Data((begin + selected + keys).utf8))
        expect(parser.value.status == .negotiating, "Unauthenticated exchange is not protected connection")
        for byte in authenticated.utf8 { parser.consume(Data([byte])) }
        expect(parser.value.status == .postQuantum, "Split-byte authenticated PQ parse")
        parser.consume(Data(begin.utf8))
        expect(parser.value.status == .negotiating, "Rekey must clear completed status")
        parser.consume(Data(("debug1: kex: algorithm: curve25519-sha256\n" + keys).utf8))
        expect(parser.value.status == .traditional, "Rekey must publish new result")
        parser.loseObservation()
        parser.consume(Data((begin + selected + keys + authenticated).utf8))
        expect(parser.value.status == .unknown, "Lost observation remains unknown")
        var unknown = SSHProtectionParser()
        unknown.consume(Data((begin + "debug1: kex: algorithm: future-kem\n" + keys + authenticated).utf8))
        expect(unknown.value.status == .unknown, "Unknown algorithm cannot become PQ")
        var missing = SSHProtectionParser()
        missing.consume(Data(authenticated.utf8))
        expect(missing.value.status == .unknown, "Missing exchange evidence")
        var multiplexed = SSHProtectionParser()
        multiplexed.consume(Data(("debug1: auto-mux: Trying existing master\n" + begin + selected + keys + authenticated).utf8))
        expect(multiplexed.value.status == .unknown, "Shared transport must not infer KEX")
        var longLine = SSHProtectionParser()
        longLine.consume(Data(repeating: 65, count: 8193))
        expect(longLine.value.status == .unknown, "Overlong line loses observation")
        let stream = try SSHDiagnosticStream()
        let writer = try FileHandle(forWritingTo: stream.url)
        try writer.write(contentsOf: Data((begin + selected + keys + authenticated).utf8))
        expect(stream.snapshot().protection.status == .postQuantum, "Real FIFO state publication")
        stream.discardAuthenticationBytes()
        try writer.write(contentsOf: Data((begin + "debug1: kex: algorithm: curve25519-sha256\n" + keys).utf8))
        let nextState = stream.snapshot()
        expect(nextState.protection.status == .traditional && nextState.bytes.isEmpty, "Continuous observation without raw retention")
        try writer.close()
        expect(stream.snapshot().protection.status == .unknown, "EOF invalidates observation")
        stream.close()
        expect(!FileManager.default.fileExists(atPath: stream.url.path), "FIFO cleanup")
        var host = HostProfile()
        host.hostname = "pq-fixture.invalid"
        host.username = "fixture"
        let all = SSHClientCapabilities(version: "fixture", keyExchangeAlgorithms: Set(SSHPostQuantumPolicy.recognizedAlgorithms))
        let normal = try SSHArgumentBuilder.arguments(for: host)
        expect(!normal.contains(where: { $0.hasPrefix("KexAlgorithms=") || $0.hasPrefix("ControlPath=") }), "Normal behavior changed")
        let required = try SSHPostQuantumPolicy.settingRequired(true, for: host)
        expect(host.algorithmMode == .systemDefault, "Original changed")
        let args = try SSHArgumentBuilder.arguments(for: required, capabilities: all)
        expect(args.filter { $0.hasPrefix("KexAlgorithms=") }.count == 1, "Duplicate KEX")
        expect(args.contains("ControlPath=none") && args.contains("ControlMaster=no") && args.contains("ControlPersist=no"), "Multiplex bypass")
        expect(args.last == "fixture@pq-fixture.invalid", "Destination displaced")
        reject(.capabilityUnavailable) { _ = try SSHArgumentBuilder.arguments(for: required) }
        reject(.noSupportedAlgorithm) {
            _ = try SSHArgumentBuilder.arguments(for: required, capabilities: SSHClientCapabilities(version: "fixture", keyExchangeAlgorithms: ["curve25519-sha256"]))
        }
        let single = SSHClientCapabilities(version: "fixture", keyExchangeAlgorithms: [SSHPostQuantumPolicy.recognizedAlgorithms[2]])
        let reduced = try SSHArgumentBuilder.arguments(for: required, capabilities: single)
        expect(reduced.contains("KexAlgorithms=" + SSHPostQuantumPolicy.recognizedAlgorithms[2]), "Local subset")
        expect(SSHPostQuantumPolicy.requiredAlgorithms(for: required)?.count == 3, "Saved policy narrowed")
        for invalid in ["", "+mlkem768x25519-sha256", "^mlkem768x25519-sha256", "*", "mlkem768x25519-sha256,", "mlkem768x25519-sha256,curve25519-sha256", "unknown-kem"] {
            var custom = required
            custom.customAlgorithms.keyExchangeAlgorithms = invalid
            expect(SSHPostQuantumPolicy.requiredAlgorithms(for: custom) == nil, "Invalid strict classification")
            if !invalid.isEmpty { reject(.customConflict) { _ = try SSHPostQuantumPolicy.settingRequired(true, for: custom) } }
        }
        var duplicate = required
        duplicate.customAlgorithms.keyExchangeAlgorithms = "mlkem768x25519-sha256,mlkem768x25519-sha256"
        expect(SSHPostQuantumPolicy.requiredAlgorithms(for: duplicate) == ["mlkem768x25519-sha256"], "Duplicate handling")
        expect(try SSHPostQuantumPolicy.settingRequired(true, for: duplicate) == duplicate, "Existing narrow list changed")
        for mode in AlgorithmMode.allCases {
            var original = host
            original.algorithmMode = mode
            original.customAlgorithms.keyExchangeAlgorithms = "curve25519-sha256"
            reject(.customConflict) { _ = try SSHPostQuantumPolicy.settingRequired(true, for: original) }
            expect(original.customAlgorithms.keyExchangeAlgorithms == "curve25519-sha256", "Existing custom value overwritten")
        }
        var inactive = host
        inactive.customAlgorithms.ciphers = "aes128-ctr"
        reject(.customConflict) { _ = try SSHPostQuantumPolicy.settingRequired(true, for: inactive) }
        var rsa = host
        rsa.algorithmMode = .rsaCompatibility
        let rsaRequired = try SSHPostQuantumPolicy.settingRequired(true, for: rsa)
        let rsaOff = try SSHPostQuantumPolicy.settingRequired(false, for: rsaRequired)
        expect(rsaOff.customAlgorithms.hostKeyAlgorithms == "+ssh-rsa" && rsaOff.customAlgorithms.publicKeyAlgorithms == "+ssh-rsa", "RSA lost")
        expect(try !SSHArgumentBuilder.arguments(for: rsaOff).contains(where: { $0.hasPrefix("KexAlgorithms=") }), "Off should use system KEX")
        var custom = host
        custom.algorithmMode = .custom
        custom.customAlgorithms.ciphers = "aes256-gcm@openssh.com"
        let strictCustom = try SSHPostQuantumPolicy.settingRequired(true, for: custom)
        let restored = try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(strictCustom))
        expect(try SSHPostQuantumPolicy.settingRequired(false, for: restored).customAlgorithms == custom.customAlgorithms, "Roundtrip loses custom cipher")
        let imported = try HostTransferService.decodeImport(data: HostTransferService.exportData(groups: [], hosts: [strictCustom]))
        let merged = try HostTransferService.merge(existing: InventoryDocument(), payload: imported, duplicatePolicy: .keepBoth)
        expect(merged.document.hosts[0].customAlgorithms == strictCustom.customAlgorithms, "Export/import lost policy")
        reject(.notRequired) { _ = try SSHPostQuantumPolicy.settingRequired(false, for: custom) }
        let keyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(required)) as! [String: Any]
        expect(keyJSON["requiresPostQuantum"] == nil, "New schema field")

        let version = Data("OpenSSH_10.2p1, fixture\n".utf8)
        let supported = Data("curve25519-sha256\nmlkem768x25519-sha256\n".utf8)
        expect(SSHCapabilityService.parse(version: version, algorithms: supported).capabilities?.postQuantumAlgorithms == ["mlkem768x25519-sha256"], "Capability parse")
        expect(SSHCapabilityService.parse(version: version, algorithms: Data("curve25519-sha256\n".utf8)).capabilities?.postQuantumAlgorithms.isEmpty == true, "Supported without PQ")
        for invalid in [Data(), Data([0xff]), Data("bad algorithm\n".utf8), Data(repeating: 65, count: 32769)] {
            expect(SSHCapabilityService.parse(version: version, algorithms: invalid) == .unavailable, "Malformed capabilities accepted")
        }
        expect(SSHCapabilityService.parse(version: Data("OpenSSH_10\nextra".utf8), algorithms: supported) == .unavailable, "Multiline version accepted")
        expect(SSHCapabilityService.parse(version: Data("unrecognized".utf8), algorithms: supported) == .unavailable, "Unknown implementation accepted")

        // Each process is a local deterministic fixture, never an SSH login.
        expect(!SSHCapabilityService.captureForTesting(executable: "/usr/bin/false", arguments: []), "Nonzero exit accepted")
        expect(!SSHCapabilityService.captureForTesting(executable: "/not-a-real-executable", arguments: []), "Launch failure accepted")
        let start = ProcessInfo.processInfo.systemUptime
        expect(!SSHCapabilityService.captureForTesting(executable: "/bin/sleep", arguments: ["5"]), "Timeout accepted")
        expect(ProcessInfo.processInfo.systemUptime - start < 2, "Timeout cleanup unbounded")
        expect(!SSHCapabilityService.captureForTesting(executable: "/usr/bin/yes", arguments: [], timeout: 1, limit: 512), "Overflow accepted")
        let actual = await SSHCapabilityService.shared.query(forceRefresh: true)
        expect(actual.capabilities != nil, "Local SSH query failed")
        let cached = await SSHCapabilityService.shared.query()
        expect(actual == cached, "Cached result changed")
        let mainThreadResult = await MainActor.run { SSHCapabilityService.shared.queryFromWorker() }
        expect(mainThreadResult == .unavailable, "Blocking capability query allowed on main thread")
        async let first = SSHCapabilityService.shared.query()
        async let second = SSHCapabilityService.shared.query()
        let simultaneous = await (first, second)
        expect(simultaneous.0 == actual && simultaneous.1 == actual, "Concurrent cache mismatch")
        if let capability = actual.capabilities {
            let live = try SSHArgumentBuilder.arguments(for: required, capabilities: capability)
            expect(live.contains("ControlPath=none"), "Actual capabilities bypass isolation")
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MYTERM_PQ_TEST_DIRECTORY"]!)
            let config = root.appendingPathComponent("synthetic-config")
            try "Host *\n ControlMaster auto\n ControlPath /private/tmp/unused-pq-fixture-master\n KexAlgorithms curve25519-sha256\n".write(to: config, atomically: true, encoding: .utf8)
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-G", "-F", config.path] + live
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            expect(process.terminationStatus == 0, "Effective configuration failed")
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            expect(!lines.contains(where: { $0.hasPrefix("controlpath ") && $0 != "controlpath none" }), "Configuration retains shared socket")
            expect(lines.contains("kexalgorithms " + capability.postQuantumAlgorithms.joined(separator: ",")), "Configuration does not enforce exact local intersection")
        }
        print("SSH post-quantum policy and observation: \(checks) checks passed (local-only; no App or network connections).")
    }
}
