#!/bin/zsh
# Standalone local-only policy/capability suite. Does not call other test suites.
set -euo pipefail
project_dir="${0:A:h:h}"
test_dir="$(mktemp -d /private/tmp/MyTerm-SSH-PQ-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
# Only the argument builder's filesystem boundary is substituted. Production
# policy, codecs, capability process runner, and parameter assembly are compiled.
cat > "$test_dir/AppPaths.swift" <<'SWIFT'
import Foundation
enum AppPaths {
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MYTERM_PQ_TEST_DIRECTORY"]!)
    static var knownHostsFile: URL { root.appendingPathComponent("known_hosts") }
    static var importedKnownHostsRawFile: URL { root.appendingPathComponent("known_hosts-imported") }
    static func prepare() throws { }
    static func createSSHConnectionLog() throws -> URL {
        let url = root.appendingPathComponent("ssh-connection-\(UUID().uuidString).log")
        try Data().write(to: url)
        return url
    }
    static func removeSSHConnectionLog(_ url: URL?) {
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
SWIFT
mkdir -p "$project_dir/.build/pq-module-cache"
swiftc -module-cache-path "$project_dir/.build/pq-module-cache" -swift-version 5 -parse-as-library -D MYTERM_SELF_TESTS \
 Sources/MySSHClient/Models/HostProfile.swift \
 Sources/MySSHClient/Models/InventoryDocument.swift \
 Sources/MySSHClient/Models/HostTransferDocument.swift \
 Sources/MySSHClient/Models/SSHPostQuantumPolicy.swift \
 Sources/MySSHClient/Services/SSHCapabilityService.swift Sources/MySSHClient/Models/SSHNegotiatedProtection.swift Sources/MySSHClient/Services/SSHDiagnosticStream.swift Sources/MySSHClient/Services/SSHConnectionDiagnostics.swift \
 Sources/MySSHClient/Services/SSHArgumentBuilder.swift \
 "$test_dir/AppPaths.swift" SelfTests/SSHPostQuantumTests.swift -o "$test_dir/tests"
MYTERM_PQ_TEST_DIRECTORY="$test_dir" "$test_dir/tests"
