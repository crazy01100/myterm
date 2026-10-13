#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
test_dir="$(mktemp -d /private/tmp/MyTerm-bookmarks-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
swift build -c debug
build_dir="$(swift build -c debug --show-bin-path)"
sodium_headers="$project_dir/.build/checkouts/swift-sodium/Clibsodium.xcframework/macos-arm64_arm64e_x86_64/Headers/Clibsodium"
swiftc -swift-version 5 -parse-as-library \
 -I "$build_dir/Modules" -Xcc -fmodule-map-file="$sodium_headers/module.modulemap" -Xcc -I -Xcc "$sodium_headers" \
 Sources/MySSHClient/Models/SFTPDirectoryBookmark.swift \
 Sources/MySSHClient/Models/SFTPBookmarkSync.swift \
 Sources/MySSHClient/Models/SyncModels.swift \
 Sources/MySSHClient/Models/VaultCryptoModels.swift \
 Sources/MySSHClient/Services/AppPaths.swift \
 Sources/MySSHClient/Services/SFTPBookmarkStore.swift \
 Sources/MySSHClient/Services/VaultCrypto.swift \
 Sources/MySSHClient/Services/VaultMasterKeyStore.swift \
 Sources/MySSHClient/Services/LocalSecretVaultStore.swift \
 Sources/MySSHClient/Services/KeychainStore.swift \
 Sources/MySSHClient/Services/SFTPBookmarkSyncCodec.swift \
 Sources/MySSHClient/Services/FirestoreBookmarkBackend.swift \
 Sources/MySSHClient/Services/SFTPBookmarkSyncEngine.swift \
 SelfTests/SFTPBookmarkTests.swift \
 "$build_dir"/Sodium.build/*.o "$build_dir"/_Clibsodium.build/*.o "$build_dir/libsodium.a" \
 -o "$test_dir/tests"
"$test_dir/tests"
