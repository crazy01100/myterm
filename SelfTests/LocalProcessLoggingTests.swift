import Foundation
import Darwin
@testable import SwiftTerm

private final class Probe: LocalProcessDelegate {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var ended = false
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lock.lock(); ended = true; lock.unlock()
    }
    func dataReceived(slice: ArraySlice<UInt8>) {
        lock.lock(); bytes.append(contentsOf: slice); lock.unlock()
    }
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
    var output: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
    var stopped: Bool {
        lock.lock(); defer { lock.unlock() }; return ended
    }
}

@main
struct LocalProcessLoggingTests {
    static func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
    static func main() {
        let probe = Probe()
        let process = LocalProcess(delegate: probe, dispatchQueue: DispatchQueue(label: "logging-test"))
        process.debugIO = true
        let secret = "MyTerm-fixture-only-9Q7!"
        let payload = Array((secret + "\n").utf8)
        let pipe = Pipe()
        fflush(stdout); fflush(stderr)
        let originalOut = dup(STDOUT_FILENO), originalErr = dup(STDERR_FILENO)
        precondition(originalOut >= 0 && originalErr >= 0)
        precondition(dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0)
        precondition(dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) >= 0)
        process.send(data: payload[...]) // No process: must not log or enqueue input.
        let idleCount = process.sendCount
        process.startProcess(executable: "/bin/sh", args: ["-c", "stty -echo; printf 'READY\\n'; IFS= read -r value; printf '%s\\n' \"$value\""], environment: ["PATH=/usr/bin:/bin", "TERM=xterm"])
        let ready = wait { probe.output.contains("READY") }
        if ready { process.send(data: payload[...]) }
        let delivered = wait { probe.output.contains(secret) }
        let stopped = wait { probe.stopped }
        if process.running { process.terminate() }
        _ = wait { !process.running }
        let count = process.sendCount
        process.send(data: payload[...]) // Stopped child: no extra send/log.
        // Drain asynchronous completion logging before restoring descriptors.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        fflush(stdout); fflush(stderr)
        precondition(dup2(originalOut, STDOUT_FILENO) >= 0 && dup2(originalErr, STDERR_FILENO) >= 0)
        close(originalOut); close(originalErr)
        try! pipe.fileHandleForWriting.close()
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let checks: [(Bool, String)] = [
            (idleCount == 0, "idle process ignores input"),
            (ready, "isolated PTY child starts"),
            (delivered, "PTY receives unchanged synthetic input"),
            (stopped, "child termination is delivered"),
            (count == 1 && process.sendCount == count, "stopped process ignores input"),
            (log.contains("Queuing bytes=\(payload.count)"), "debug branch logs byte count"),
            (!log.contains(secret), "debug output contains no plaintext payload"),
            (!log.contains(payload.map(String.init).joined(separator: ", ")), "debug output contains no recoverable byte array")
        ]
        for (pass, name) in checks { print("\(pass ? "PASS" : "FAIL"): \(name)") }
        exit(checks.allSatisfy { $0.0 } ? 0 : 1)
    }
}
