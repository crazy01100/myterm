#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
test_dir="$(mktemp -d /private/tmp/MySSHClient-crypto-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

cd "$project_dir"
crypto_build_dir="$(swift build -c debug --show-bin-path)"
sodium_headers="$project_dir/.build/checkouts/swift-sodium/Clibsodium.xcframework/macos-arm64_arm64e_x86_64/Headers/Clibsodium"
swiftc \
    -I "$crypto_build_dir/Modules" \
    -Xcc -fmodule-map-file="$sodium_headers/module.modulemap" \
    -Xcc -I \
    -Xcc "$sodium_headers" \
    Sources/MySSHClient/Models/SyncModels.swift \
    Sources/MySSHClient/Models/HostProfile.swift \
    Sources/MySSHClient/Models/InventoryDocument.swift \
    Sources/MySSHClient/Models/FirestoreMetadataSnapshot.swift \
    Sources/MySSHClient/Models/VaultCryptoModels.swift \
    Sources/MySSHClient/Services/AppPaths.swift \
    Sources/MySSHClient/Services/KeychainStore.swift \
    Sources/MySSHClient/Services/VaultMasterKeyStore.swift \
    Sources/MySSHClient/Services/VaultCrypto.swift \
    Sources/MySSHClient/Services/VaultEnvelopeStore.swift \
    Sources/MySSHClient/Services/FirestoreVaultBackend.swift \
    Sources/MySSHClient/Services/MetadataSyncCodec.swift \
    Sources/MySSHClient/Services/FirestoreMetadataBackend.swift \
    Sources/MySSHClient/Services/PasswordSync.swift \
    Sources/MySSHClient/Services/SyncDeviceIdentityStore.swift \
    Sources/MySSHClient/Services/MetadataSyncBaselineStore.swift \
    Sources/MySSHClient/Services/MetadataManualSync.swift \
    Sources/MySSHClient/Services/MetadataSyncPreview.swift \
    SelfTests/VaultCryptoTests.swift \
    "$crypto_build_dir"/Sodium.build/*.o \
    "$crypto_build_dir"/_Clibsodium.build/*.o \
    "$crypto_build_dir/libsodium.a" \
    -o "$test_dir/VaultCryptoTests"
"$test_dir/VaultCryptoTests"
