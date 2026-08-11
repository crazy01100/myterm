#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source "$project_dir/scripts/code-signing-common.sh"

if (( $# != 1 )); then
    print -u2 -- "用法：scripts/verify-code-signing-key-backup.sh /絕對路徑/MyTerm-Code-Signing-Backup.dmg"
    exit 64
fi
backup_path="${1:A}"
[[ -f "$backup_path" ]] || { print -u2 -- "找不到備份：$backup_path"; exit 66; }

mount_dir="$(mktemp -d /private/tmp/MyTerm-CodeSign-mount.XXXXXX)"
test_dir="$(mktemp -d /private/tmp/MyTerm-CodeSign-restore.XXXXXX)"
test_keychain="$test_dir/restore-test.keychain-db"
test_password="$(/usr/bin/uuidgen)$(/usr/bin/uuidgen)"
mounted=0

cleanup() {
    /usr/bin/security delete-keychain "$test_keychain" >/dev/null 2>&1 || true
    if (( mounted == 1 )); then
        /usr/bin/hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
    fi
    /bin/rm -rf -- "$mount_dir" "$test_dir"
}
trap cleanup EXIT INT TERM

print -r -- "macOS 接下來會要求 AES-256 備份密碼；請勿在對話中提供密碼。"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$backup_path" >/dev/null
mounted=1
p12_file="$mount_dir/MyTerm-Code-Signing-Identity.p12"
p12_password_file="$mount_dir/MyTerm-Code-Signing-Identity-Passphrase.txt"
[[ -f "$p12_file" && -f "$p12_password_file" ]] || {
    print -u2 -- "備份缺少 Code Signing 身分或其內層匯入密碼。"
    exit 1
}
p12_password="$(/usr/bin/tr -d '\r\n' < "$p12_password_file")"
[[ ${#p12_password} -ge 48 ]] || { print -u2 -- "備份內層匯入密碼格式錯誤。"; exit 1; }

/usr/bin/security create-keychain -p "$test_password" "$test_keychain"
/usr/bin/security unlock-keychain -p "$test_password" "$test_keychain"
/usr/bin/security import "$p12_file" -k "$test_keychain" -f pkcs12 -P "$p12_password" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

identity_hash="$(/usr/bin/security find-certificate -a -Z "$test_keychain" \
    | /usr/bin/sed -n 's/^SHA-1 hash: //p' | /usr/bin/head -1)"
[[ "$identity_hash" =~ '^[0-9A-Fa-f]{40}$' ]] || { print -u2 -- "隔離 Keychain 找不到憑證。"; exit 1; }

probe_app="$test_dir/MyTerm.app"
/bin/mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/Resources"
/bin/cp /usr/bin/true "$probe_app/Contents/MacOS/MySSHClient"
/usr/bin/plutil -create xml1 "$probe_app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string "tw.local.MySSHClient" "$probe_app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string "MySSHClient" "$probe_app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string "APPL" "$probe_app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleName -string "MyTerm" "$probe_app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "1" "$probe_app/Contents/Info.plist"
/usr/bin/codesign --force --timestamp=none --keychain "$test_keychain" --sign "$identity_hash" "$probe_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$probe_app"
validate_stable_code_signature "$project_dir" "$probe_app"

print -r -- "備份已通過：AES-256 解鎖、隔離 Keychain 還原、私鑰簽署、憑證指紋與 designated requirement 比對。"
print -r -- "備份 SHA-256：$(/usr/bin/shasum -a 256 "$backup_path" | /usr/bin/awk '{print $1}')"
