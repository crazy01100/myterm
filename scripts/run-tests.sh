#!/bin/zsh
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/run-tests.sh

Runs the core MyTerm self-tests, OAuth loopback tests, and the complete
encryption/synchronization test suite. No App is built or launched.
EOF
}

if (( $# > 0 )); then
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 -- "Unknown option: $1"
            usage >&2
            exit 64
            ;;
    esac
fi

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
    Sources/MySSHClient/Models/TerminalWorkspace.swift \
    Sources/MySSHClient/Services/AppPaths.swift \
    Sources/MySSHClient/Services/AppShortcutStore.swift \
    Sources/MySSHClient/Services/CloudConfiguration.swift \
    Sources/MySSHClient/Services/OAuthSecurity.swift \
    Sources/MySSHClient/Services/GoogleFirebaseAuthClient.swift \
    Sources/MySSHClient/Services/LocalSecretVaultStore.swift \
    Sources/MySSHClient/Services/KeychainStore.swift \
    Sources/MySSHClient/Services/CloudSessionKeychainStore.swift \
    Sources/MySSHClient/Services/LoginPasswordPromptDetector.swift \
    Sources/MySSHClient/Services/SSHLoginPasswordCapture.swift \
    Sources/MySSHClient/Services/PasswordChangeCapture.swift \
    Sources/MySSHClient/Services/SyncBackend.swift \
    Sources/MySSHClient/Services/SyncMutationJournal.swift \
    Sources/MySSHClient/Services/SyncSettingsStore.swift \
    Sources/MySSHClient/Services/HostPlatformDetector.swift \
    Sources/MySSHClient/Services/HostPlatformProbe.swift \
    Sources/MySSHClient/Services/SSHConnectionDiagnostics.swift \
    Sources/MySSHClient/Services/SSHArgumentBuilder.swift \
    Sources/MySSHClient/Services/SFTPProtocol.swift \
    Sources/MySSHClient/Services/SFTPClient.swift \
    SelfTests/main.swift \
    -o "$test_dir/MySSHClientSelfTests"
MYTERM_SECRET_VAULT_KEYCHAIN_SERVICE="tw.local.MySSHClient.tests.$$.core" \
MYTERM_SECRET_VAULT_FILE="$test_dir/core-secret-vault.json" \
    "$test_dir/MySSHClientSelfTests"

swiftc \
    Sources/MySSHClient/Services/OAuthSecurity.swift \
    Sources/MySSHClient/Services/LoopbackOAuthListener.swift \
    SelfTests/OAuthLoopbackTests.swift \
    -o "$test_dir/OAuthLoopbackTests"
"$test_dir/OAuthLoopbackTests"

MYTERM_SECRET_VAULT_TEST_RUN_ID="$$" "$project_dir/scripts/run-crypto-tests.sh"
