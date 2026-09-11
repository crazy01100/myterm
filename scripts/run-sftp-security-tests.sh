#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
test_dir="$(mktemp -d /private/tmp/MyTerm-SFTP-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
swiftc -D MYTERM_SELF_TESTS \
 Sources/MySSHClient/Models/HostProfile.swift Sources/MySSHClient/Models/SFTPModels.swift \
 Sources/MySSHClient/Services/AppPaths.swift Sources/MySSHClient/Services/SSHArgumentBuilder.swift \
 Sources/MySSHClient/Services/KeychainStore.swift Sources/MySSHClient/Services/LocalSecretVaultStore.swift \
 Sources/MySSHClient/Services/SFTPProtocol.swift Sources/MySSHClient/Services/SFTPClient.swift \
 SelfTests/SFTPSecurityTests.swift -o "$test_dir/tests"
"$test_dir/tests" "$project_dir/Tests/Security/fake_sftp.py"
