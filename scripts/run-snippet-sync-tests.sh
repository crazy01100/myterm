#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
test_dir="$(mktemp -d /private/tmp/MyTerm-snippet-sync-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
swift build -c debug
build_dir="$(swift build -c debug --show-bin-path)"
sodium_headers="$project_dir/.build/checkouts/swift-sodium/Clibsodium.xcframework/macos-arm64_arm64e_x86_64/Headers/Clibsodium"
swiftc -swift-version 5 -parse-as-library \
 -I "$build_dir/Modules" -Xcc -fmodule-map-file="$sodium_headers/module.modulemap" -Xcc -I -Xcc "$sodium_headers" \
 Sources/MySSHClient/Models/CommandSnippet.swift \
 Sources/MySSHClient/Models/CommandSnippetSync.swift \
 Sources/MySSHClient/Models/SyncModels.swift \
 Sources/MySSHClient/Models/VaultCryptoModels.swift \
 Sources/MySSHClient/Services/AppPaths.swift \
 Sources/MySSHClient/Services/CommandSnippetStore.swift \
 Sources/MySSHClient/Services/VaultCrypto.swift \
 Sources/MySSHClient/Services/VaultMasterKeyStore.swift \
 Sources/MySSHClient/Services/LocalSecretVaultStore.swift \
 Sources/MySSHClient/Services/KeychainStore.swift \
 Sources/MySSHClient/Services/CommandSnippetSyncCodec.swift \
 Sources/MySSHClient/Services/FirestoreSnippetBackend.swift \
 Sources/MySSHClient/Services/SnippetSyncEngine.swift \
 SelfTests/SnippetSyncTests.swift \
 "$build_dir"/Sodium.build/*.o "$build_dir"/_Clibsodium.build/*.o "$build_dir/libsodium.a" \
 -o "$test_dir/tests"
"$test_dir/tests"
