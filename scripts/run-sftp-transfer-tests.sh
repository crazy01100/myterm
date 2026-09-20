#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
python_executable="$("$project_dir/scripts/project-python.sh" -c 'import sys; print(sys.executable)')"
test_dir="$(mktemp -d /private/tmp/MyTerm-SFTP-transfer-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
swiftc -swift-version 5 -parse-as-library -D MYTERM_SELF_TESTS \
 Sources/MySSHClient/Models/HostProfile.swift Sources/MySSHClient/Models/SFTPModels.swift \
 Sources/MySSHClient/Services/AppPaths.swift Sources/MySSHClient/Services/SSHArgumentBuilder.swift \
 Sources/MySSHClient/Services/KeychainStore.swift Sources/MySSHClient/Services/LocalSecretVaultStore.swift \
 Sources/MySSHClient/Services/SFTPProtocol.swift Sources/MySSHClient/Services/SFTPClient.swift \
 Sources/MySSHClient/Services/SFTPHostOpeningController.swift Sources/MySSHClient/Services/SFTPBrowserStores.swift \
 SelfTests/SFTPTransferTests.swift -o "$test_dir/tests"
"$test_dir/tests" "$python_executable" "$project_dir/Tests/Security/fake_sftp_transfer.py"
