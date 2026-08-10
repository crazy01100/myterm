#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
test_dir="$(mktemp -d /private/tmp/MySSHClient-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

cd "$project_dir"
swiftc -D MYTERM_SELF_TESTS \
    Sources/MySSHClient/Models/HostProfile.swift \
    Sources/MySSHClient/Models/HostTransferDocument.swift \
    Sources/MySSHClient/Models/InventoryDocument.swift \
    Sources/MySSHClient/Models/KnownHostRecord.swift \
    Sources/MySSHClient/Models/SerialConfiguration.swift \
    Sources/MySSHClient/Models/SFTPModels.swift \
    Sources/MySSHClient/Models/SyncModels.swift \
    Sources/MySSHClient/Services/AppPaths.swift \
    Sources/MySSHClient/Services/AppShortcutStore.swift \
    Sources/MySSHClient/Services/CloudConfiguration.swift \
    Sources/MySSHClient/Services/OAuthSecurity.swift \
    Sources/MySSHClient/Services/GoogleFirebaseAuthClient.swift \
    Sources/MySSHClient/Services/KeychainStore.swift \
    Sources/MySSHClient/Services/CloudSessionKeychainStore.swift \
    Sources/MySSHClient/Services/LoginPasswordPromptDetector.swift \
    Sources/MySSHClient/Services/SSHLoginPasswordCapture.swift \
    Sources/MySSHClient/Services/SyncBackend.swift \
    Sources/MySSHClient/Services/SyncMutationJournal.swift \
    Sources/MySSHClient/Services/SyncSettingsStore.swift \
    Sources/MySSHClient/Services/HostPlatformDetector.swift \
    Sources/MySSHClient/Services/SSHArgumentBuilder.swift \
    Sources/MySSHClient/Services/SFTPProtocol.swift \
    Sources/MySSHClient/Services/SFTPClient.swift \
    SelfTests/main.swift \
    -o "$test_dir/MySSHClientSelfTests"
"$test_dir/MySSHClientSelfTests"

swiftc \
    Sources/MySSHClient/Services/OAuthSecurity.swift \
    Sources/MySSHClient/Services/LoopbackOAuthListener.swift \
    SelfTests/OAuthLoopbackTests.swift \
    -o "$test_dir/OAuthLoopbackTests"
"$test_dir/OAuthLoopbackTests"

"$project_dir/scripts/run-crypto-tests.sh"
