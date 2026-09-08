#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
test_dir="$(mktemp -d /private/tmp/MyTerm-sync-reliability.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
swiftc -D MYTERM_SELF_TESTS \
    Sources/MySSHClient/Models/HostProfile.swift \
    Sources/MySSHClient/Models/ConnectionAuditRecord.swift \
    Sources/MySSHClient/Services/AppPaths.swift \
    Sources/MySSHClient/Services/SyncDeviceIdentityStore.swift \
    Sources/MySSHClient/Services/ConnectionAuditStore.swift \
    Sources/MySSHClient/Services/SyncDiagnosticsJournal.swift \
    Sources/MySSHClient/Services/AutomaticSyncCoordinator.swift \
    SelfTests/SyncReliabilityTests.swift \
    -o "$test_dir/SyncReliabilityTests"
"$test_dir/SyncReliabilityTests"

swiftc -D MYTERM_SELF_TESTS \
    Sources/MySSHClient/Services/AppPaths.swift \
    Sources/MySSHClient/Services/CloudAccountStore.swift \
    Sources/MySSHClient/Services/SyncSettingsStore.swift \
    Sources/MySSHClient/Services/SyncDiagnosticsJournal.swift \
    Sources/MySSHClient/Services/AutomaticSyncCoordinator.swift \
    SelfTests/CloudAccountRecoveryTests.swift \
    -o "$test_dir/CloudAccountRecoveryTests"
"$test_dir/CloudAccountRecoveryTests"
