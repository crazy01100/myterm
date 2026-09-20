import Foundation
import Darwin

@main struct SFTPTransferTests {
    static var passed = 0
    static func check(_ ok: Bool, _ name: String) {
        guard ok else { fatalError("FAIL: \(name)") }
        passed += 1; print("PASS: \(name)")
    }
    static func testTiming() {
        var item = SFTPTransferItem(id: UUID(), direction: .upload, name: "fixture",
                                    completedBytes: 0, totalBytes: 10_000, state: .transferring)
        check(item.progressDescription == "0.0%" && item.fractionCompleted == 0, "known empty progress starts at zero")
        item.completedBytes = 60
        check(item.progressDescription == "0.6%" && item.fractionCompleted == 0.006, "small progress has a readable percentage and proportional fill")
        item.completedBytes = 5_000
        check(item.progressDescription == "50.0%" && item.fractionCompleted == 0.5, "half transfer shows half fill and percentage")
        item.completedBytes = 9_999
        check(item.progressDescription == "99.9%", "rounding cannot prematurely claim one hundred percent")
        item.completedBytes = 10_000
        check(item.progressDescription == "正在完成" && item.progressPercentage == 99.9, "all bytes sent waits for final file operation")
        item.state = .completed
        check(item.progressDescription == "100.0%", "successful publication reports one hundred percent")
        item.state = .cancelled
        check(item.progressDescription == "99.9%", "cancelled publication cannot appear completed")
        item.completedBytes = 5_000; item.state = .failed("fixture")
        check(item.progressDescription == "50.0%", "failed transfer keeps its measured percentage")
        item.totalBytes = nil
        check(item.progressPercentage == nil && item.fractionCompleted == nil && item.progressDescription == "總大小未知", "unknown total does not invent a percentage")
        item.totalBytes = 0; item.completedBytes = 0; item.state = .transferring
        check(item.progressDescription == "正在完成" && item.fractionCompleted == nil, "zero byte file waits for publication without division by zero")
        item.state = .completed
        check(item.progressDescription == "100.0%", "zero byte file completes only on success")
        var timing = SFTPTransferTiming()
        check(timing.speed(at: 100) == nil && timing.elapsed(at: 100) == 0, "waiting has no invented rate or elapsed time")
        timing.start(now: 100, date: .distantPast)
        timing.record(bytes: 1_000, now: 101)
        check(timing.speed(at: 101) == 1_000, "rate uses byte delta and monotonic time")
        check(timing.remaining(bytes: 1_000, total: 3_000, now: 101) == 2, "ETA uses remaining bytes")
        check(timing.remaining(bytes: 1_000, total: nil, now: 101) == nil, "unknown directory size has no ETA")
        check(timing.remaining(bytes: 0, total: 0, now: 101) == nil, "zero-size file has no infinity or negative ETA")
        check(timing.speed(at: 105) == 0 && timing.remaining(bytes: 1_000, total: 3_000, now: 105) == nil, "stalled transfer stops displaying stale speed")
        timing.record(bytes: 1, now: 102)
        check(timing.samples.last?.bytes == 1_000, "out-of-order byte counter rejected")
        timing.finish(now: 106, date: .distantFuture)
        check(timing.elapsed(at: 999) == 6 && timing.speed(at: 999) == nil, "completion freezes monotonic duration despite wall-clock jump")
        let token = SFTPTransferCancellation()
        token.cancel()
        do { try token.beginCommit(); check(false,"cancelled operation must not commit") } catch { check(true,"cancel wins before commit") }
        let committed = SFTPTransferCancellation()
        try! committed.beginCommit()
        check(!committed.cancel(), "late cancel cannot claim publication was undone")
    }

    @MainActor static func testScheduler(root: URL, python: URL, peer: String) async throws {
        let area = root.appendingPathComponent("scheduler")
        let remote = area.appendingPathComponent("remote"), local = area.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let file = remote.appendingPathComponent("large")
        try Data(repeating: 66, count: 2 * 1024 * 1024).write(to: file)
        let client = try SFTPClient.connectForTesting(executableURL: python, arguments: [peer, remote.path, "slow"], responseTimeout: 1, initializationTimeout: 1)
        client.completeInitialization()
        let store = SFTPRemoteBrowserStore()
        var host = HostProfile(); host.hostname = "example.invalid"; host.username = "test"
        store.installTestConnection(client, host: host)
        let entry = SFTPDirectoryEntry(name: "large", longName: "", attributes: SFTPFileAttributes(size: 2 * 1024 * 1024, permissions: 0o100644))
        store.download(entries: [entry], to: local)
        store.download(entries: [entry], to: local)
        check(store.transferItems.map(\.state) == [.transferring, .waiting], "multiple batches have exactly one active transfer")
        let ids = store.transferItems.map(\.id)
        store.cancelTransfer(ids[1])
        check(store.transferItems[1].state == .cancelled, "queued job cancels before I/O")
        store.cancelTransfer(ids[0])
        check(store.transferItems[0].state == .cancelling, "active cancellation immediately visible")
        for _ in 0..<100 {
            if store.transferItems.allSatisfy({ $0.state.isFinished }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check(store.transferItems.allSatisfy { $0.state == .cancelled }, "active and queued cancellation converge")
        check(!FileManager.default.fileExists(atPath: local.appendingPathComponent("large").path), "cancelled queued job never writes destination")
        check(!store.openingSnapshot.isBusy, "cancelled jobs no longer block host switching")
        // Wait for the post-transfer directory refresh, then submit fresh work.
        for _ in 0..<100 { if store.state == .connected { break }; try await Task.sleep(for: .milliseconds(20)) }
        store.download(entries: [entry], to: local)
        for _ in 0..<200 {
            if store.transferItems.last?.state == .completed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check(store.transferItems.last?.state == .completed, "next transfer succeeds after operation cancellation")
        check(try Data(contentsOf: local.appendingPathComponent("large")) == Data(repeating: 66,count:2*1024*1024), "subsequent file bytes preserved")
        check(store.transferItems.last?.timing.endedAt != nil, "completion timestamp recorded")
        check(store.transferItems.last?.targetDescription.contains("example.invalid") == true, "history retains original host identity")
        store.clearCompletedTransfers()
        check(store.transferItems.isEmpty, "clear removes all ended states")
        store.disconnect()

        let second = try SFTPClient.connectForTesting(executableURL: python, arguments: [peer, remote.path, "slow"], responseTimeout: 1, initializationTimeout: 1)
        second.completeInitialization()
        store.installTestConnection(second, host: host)
        let upload = local.appendingPathComponent("upload")
        try Data(repeating: 67, count: 2 * 1024 * 1024).write(to: upload)
        store.upload(localURLs: [upload])
        store.upload(localURLs: [upload])
        check(store.transferItems.map(\.state) == [.transferring, .waiting], "upload requests become visible immediately without blocking preflight")
        store.cancelAllTransfers()
        for _ in 0..<100 { if !store.hasActiveTransfers { break }; try await Task.sleep(for: .milliseconds(20)) }
        check(store.transferItems.allSatisfy { $0.state == .cancelled }, "cancel all stops upload and queued batch")
        check(!FileManager.default.fileExists(atPath: remote.appendingPathComponent("upload").path), "cancel all cannot launch hidden upload preflight afterward")
        store.disconnect()
    }

    static func testNativeServer(root: URL) throws {
        let executable = URL(fileURLWithPath: "/usr/libexec/sftp-server")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            print("SKIP: native macOS sftp-server unavailable")
            return
        }
        let area = root.appendingPathComponent("native")
        let remote = area.appendingPathComponent("remote"), local = area.appendingPathComponent("local")
        let download = area.appendingPathComponent("download")
        for directory in [remote, local, download] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let client = try SFTPClient.connectForTesting(executableURL: executable, arguments: ["-d", remote.path], responseTimeout: 2, initializationTimeout: 2)
        defer { client.close() }
        client.completeInitialization()
        let source = local.appendingPathComponent("file"), target = remote.appendingPathComponent("file")
        let content = Data(repeating: 68, count: 256 * 1024)
        try content.write(to: source)
        try Data("old".utf8).write(to: target)
        let token = SFTPTransferCancellation()
        do {
            try client.uploadItem(at: source, to: remote.path, overwrite: true, cancellation: token) { bytes, _ in
                if bytes > 0 { token.cancel() }
            }
            check(false, "native transfer must cancel")
        } catch {
            check(try Data(contentsOf: target) == Data("old".utf8), "native server cancellation preserves original target")
        }
        try client.uploadItem(at: source, to: remote.path, overwrite: true) { _, _ in }
        check(try Data(contentsOf: target) == content, "native advertised POSIX replacement succeeds")
        let folder = local.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data().write(to: folder.appendingPathComponent("empty"))
        try client.uploadItem(at: folder, to: remote.path) { _, _ in }
        check(FileManager.default.fileExists(atPath: remote.appendingPathComponent("folder/empty").path), "native new directory and zero-byte file upload")
        let entries = try client.listDirectory(remote.path)
        guard let entry = entries.first(where: { $0.name == "folder" }) else { fatalError("missing folder") }
        try client.downloadItem(entry, from: remote.path, to: download) { _, _ in }
        check(try Data(contentsOf: download.appendingPathComponent("folder/empty")).isEmpty, "native recursive download preserves zero-byte file")
        check(try FileManager.default.contentsOfDirectory(atPath: remote.path).sorted() == ["file", "folder"], "native uploads leave no staging directories")
        check(try FileManager.default.contentsOfDirectory(atPath: download.path) == ["folder"], "native downloads leave no staging directories")
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyTerm-SFTP-P0-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let python = URL(fileURLWithPath: CommandLine.arguments[1]), peer = CommandLine.arguments[2]
        let payload = Data(repeating: 65, count: 256 * 1024)
        for mode in ["cancel", "replace", "unsupported", "version2", "directory", "commit_fail", "stall", "download", "commit_drop", "mkdir_conflict"] {
            let area=root.appendingPathComponent(mode), remote=area.appendingPathComponent("remote"), local=area.appendingPathComponent("local")
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            let target=remote.appendingPathComponent("sample"), source=local.appendingPathComponent("sample")
            try payload.write(to: source)
            if mode == "directory" {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try Data("old".utf8).write(to: target.appendingPathComponent("old"))
            } else { try Data("old".utf8).write(to: target) }
            let connectionCancellation=SFTPCancellation()
            let client=try SFTPClient.connectForTesting(executableURL: python, arguments:[peer,remote.path,mode],cancellation:connectionCancellation,responseTimeout:1,initializationTimeout:1)
            client.completeInitialization()
            let operationCancellation = SFTPTransferCancellation()
            let start=ProcessInfo.processInfo.systemUptime
            if mode == "stall" {
                DispatchQueue.global().asyncAfter(deadline:.now()+0.2) { connectionCancellation.cancel() }
            }
            if mode == "download" {
                try payload.write(to: target)
                try Data("old".utf8).write(to: source)
                let entry=SFTPDirectoryEntry(name:"sample",longName:"",attributes:SFTPFileAttributes(size:UInt64(payload.count),permissions:0o100644))
                do {
                    try client.downloadItem(entry,from:"/",to:local,overwrite:true,cancellation:operationCancellation) { _,_ in operationCancellation.cancel() }
                    check(false,"download must cancel")
                } catch { check((error as? SFTPConnectionError).map { if case .cancelled = $0 { return true }; return false } == true,"download operation cancelled") }
                check(try Data(contentsOf: source)==Data("old".utf8),"cancelled download preserves original local file")
                check(try FileManager.default.contentsOfDirectory(atPath:local.path)==["sample"],"download temporary files cleaned")
            } else {
                var success=false
                do {
                    try client.uploadItem(at:source,to:"/",overwrite:true,cancellation:operationCancellation) { bytes,_ in if mode=="cancel", bytes > 0 {operationCancellation.cancel()} }
                    success=true
                } catch {
                    check(mode != "replace","expected refusal or cancellation: \(mode)")
                    if mode == "commit_drop" {
                        if case SFTPTransferError.outcomeUnknown = error { check(true,"lost publication reply is explicitly uncertain") }
                        else { check(false,"publication uncertainty must not be reported as cancellation") }
                    }
                    if mode == "stall" {
                        if case SFTPTransferError.cleanupRequired = error { check(true,"uncleaned temporary path is surfaced") }
                        else { check(false,"lost cleanup must be surfaced") }
                    }
                }
                check(success == (mode == "replace"),"correct completion: \(mode)")
                if mode == "directory" { check(try String(contentsOf:target.appendingPathComponent("old"),encoding:.utf8)=="old","nonempty remote directory preserved") }
                else { check(try Data(contentsOf:target) == ((mode=="replace" || mode=="commit_drop") ? payload : Data("old".utf8)),"original or completed destination bytes: \(mode)") }
                let remains=try FileManager.default.contentsOfDirectory(atPath:remote.path).filter{$0.hasPrefix(".myterm-upload-")}
                check(["stall","commit_drop","mkdir_conflict"].contains(mode) ? !remains.isEmpty : remains.isEmpty,"temporary residue is accurately identified: \(mode)")
            }
            if mode != "stall" && mode != "commit_drop" { check(try client.realPath(".")=="/test","same channel stays synchronized: \(mode)") }
            else {
                check(ProcessInfo.processInfo.systemUptime-start<2,"lost/closed I/O returns within bound")
                do { _ = try client.realPath("."); check(false,"closed channel must not be reused") } catch { check(true,"hard cancellation requires new connection") }
            }
            if mode == "mkdir_conflict" {
                let containers = try FileManager.default.contentsOfDirectory(at: remote, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".myterm-upload-") }
                check(try containers.allSatisfy { try String(contentsOf: $0.appendingPathComponent("foreign"), encoding: .utf8) == "not ours" }, "refused mkdir never authorizes cleanup")
            }
            print("Elapsed \(mode): \(String(format:"%.3f",ProcessInfo.processInfo.systemUptime-start)) seconds")
            client.close()
            let pid=Int32(try String(contentsOf:remote.appendingPathComponent("peer.pid"),encoding:.utf8))!
            for _ in 0..<30 { if Darwin.kill(pid,0) != 0 { break }; try await Task.sleep(for: .milliseconds(50)) }
            check(Darwin.kill(pid,0) != 0,"fake peer exits: \(mode)")
        }
        try await testScheduler(root: root, python: python, peer: peer)
        try testNativeServer(root: root)
        testTiming()
        print("\(passed) SFTP transfer checks passed, 0 failed")
    }
}
