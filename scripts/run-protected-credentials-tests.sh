#!/bin/zsh
# Synthetic page state and a private named pasteboard only. No LA prompts,
# user vault, network, App launch, or other test suites are executed.
set -euo pipefail
project_dir="${0:A:h:h}"
test_dir="$(mktemp -d /private/tmp/MyTerm-credentials-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
mkdir -p .build/credentials-module-cache
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/credentials-module-cache \
    Sources/MySSHClient/Models/HostProfile.swift \
    Sources/MySSHClient/Models/ProtectedCredentialsPolicy.swift \
    Sources/MySSHClient/Services/LocalUserAuthentication.swift \
    Sources/MySSHClient/Services/ProtectedCredentialReader.swift \
    Sources/MySSHClient/Services/SensitiveClipboardStore.swift \
    Sources/MySSHClient/Services/ProtectedCredentialsStore.swift \
    SelfTests/ProtectedCredentialsTests.swift -o "$test_dir/tests"
"$test_dir/tests"
