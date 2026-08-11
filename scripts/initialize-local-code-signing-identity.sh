#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source "$project_dir/scripts/code-signing-common.sh"

identity_name="MyTerm Local Release"
if (( $# != 1 )); then
    print -u2 -- "用法：scripts/initialize-local-code-signing-identity.sh /絕對路徑/MyTerm-Code-Signing-Backup.dmg"
    exit 64
fi

destination="${1:A}"
[[ "$destination" == /* && "${destination:e}" == "dmg" ]] || {
    print -u2 -- "備份路徑必須是絕對路徑，且副檔名為 .dmg。"
    exit 64
}
[[ ! -e "$destination" ]] || {
    print -u2 -- "目的檔案已存在，為避免覆蓋而停止：$destination"
    exit 65
}
destination_parent="${destination:h:A}"
[[ -d "$destination_parent" && -w "$destination_parent" ]] || {
    print -u2 -- "目的資料夾不存在或無法寫入：$destination_parent"
    exit 66
}
if [[ "$destination_parent" == "${project_dir:A}" || "$destination_parent" == "${project_dir:A}"/* ]]; then
    print -u2 -- "簽署私鑰備份不可放在 MyTerm 專案目錄內。"
    exit 66
fi
if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -Fq -- "\"$identity_name\""; then
    print -u2 -- "Keychain 已有同名簽署身分，拒絕重複建立：$identity_name"
    exit 65
fi

work_dir="$(mktemp -d /private/tmp/MyTerm-CodeSign-create.XXXXXX)"
partial_destination="${destination:r}.partial.dmg"
key_file="$work_dir/MyTerm-Code-Signing-Private-Key.pem"
certificate_file="$work_dir/MyTerm-Code-Signing-Certificate.pem"
identity_file="$work_dir/MyTerm-Code-Signing-Identity.p12"
p12_password_file="$work_dir/MyTerm-Code-Signing-Identity-Passphrase.txt"
openssl_config="$work_dir/openssl.cnf"
payload_dir="$work_dir/payload"
login_keychain="$HOME/Library/Keychains/login.keychain-db"
identity_imported=0
identity_finalized=0
certificate_fingerprint=""
certificate_sha1=""

cleanup() {
    if (( identity_imported == 1 && identity_finalized == 0 )) && [[ -n "$certificate_sha1" ]]; then
        # Remove the incomplete private-key identity first, then its trust entry.
        # Do not use `delete-identity -t`: on macOS 26 it can return success while
        # leaving this self-signed identity in the login Keychain.
        /usr/bin/security delete-identity -Z "$certificate_sha1" "$login_keychain" >/dev/null 2>&1 || true
        [[ -f "$certificate_file" ]] \
            && /usr/bin/security remove-trusted-cert "$certificate_file" >/dev/null 2>&1 || true
    fi
    [[ -f "$key_file" ]] && /bin/rm -P -- "$key_file" 2>/dev/null || true
    [[ -f "$identity_file" ]] && /bin/rm -P -- "$identity_file" 2>/dev/null || true
    /bin/rm -rf -- "$work_dir"
    /bin/rm -f -- "$partial_destination"
}
trap cleanup EXIT INT TERM

umask 077
/bin/mkdir -p "$payload_dir"
print -r -- '[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no

[subject]
CN = MyTerm Local Release
O = MyTerm
OU = Local Release Signing

[extensions]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always' > "$openssl_config"

print -r -- "正在建立 10 年期的 MyTerm 固定本機發行憑證。"
/usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -days 3650 -sha256 \
    -config "$openssl_config" -keyout "$key_file" -out "$certificate_file" >/dev/null 2>&1
p12_password="$(/usr/bin/uuidgen | /usr/bin/tr -d '-')$(/usr/bin/uuidgen | /usr/bin/tr -d '-')"
print -rn -- "$p12_password" > "$p12_password_file"
/usr/bin/openssl pkcs12 -export -passout "file:$p12_password_file" \
    -name "$identity_name" -inkey "$key_file" -in "$certificate_file" -out "$identity_file"

/bin/cp "$identity_file" "$payload_dir/MyTerm-Code-Signing-Identity.p12"
/bin/cp "$p12_password_file" "$payload_dir/MyTerm-Code-Signing-Identity-Passphrase.txt"
/bin/cp "$certificate_file" "$payload_dir/MyTerm-Code-Signing-Certificate.pem"
certificate_fingerprint="$(/usr/bin/openssl x509 -in "$certificate_file" -outform DER \
    | /usr/bin/shasum -a 256 | /usr/bin/awk '{print tolower($1)}')"
certificate_sha1="$(/usr/bin/openssl x509 -in "$certificate_file" -noout -fingerprint -sha1 \
    | /usr/bin/sed 's/^.*=//' | /usr/bin/tr -d ':' | /usr/bin/tr '[:lower:]' '[:upper:]')"
print -r -- "MyTerm 固定本機 Code Signing 身分備份
建立時間：$(date '+%Y-%m-%d %H:%M:%S %z')
憑證名稱：$identity_name
憑證 SHA-256：$certificate_fingerprint
有效期間：10 年

這份 AES-256 磁碟映像包含可還原的 Code Signing 私鑰與其隨機內層匯入密碼。
不得上傳至 Git、GitHub Release、Cloudflare、Firebase 或聊天。
還原後仍需在目標 Mac 明確信任此自簽憑證的 Code Signing 用途。" \
    > "$payload_dir/MyTerm-Code-Signing-Backup.txt"
/bin/chmod 0600 "$payload_dir"/*

print -r -- "macOS 接下來會要求你設定 AES-256 備份密碼；請勿把密碼提供給 Codex。"
/usr/bin/hdiutil create -quiet -encryption AES-256 -format UDZO \
    -volname "MyTerm Code Signing Backup" -srcfolder "$payload_dir" "$partial_destination"
/usr/bin/hdiutil verify "$partial_destination" >/dev/null

print -r -- "接下來可能會出現 Keychain 與信任設定提示，這是建立固定簽署身分的一次性動作。"
/usr/bin/security import "$identity_file" -k "$login_keychain" -f pkcs12 -P "$p12_password" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
identity_imported=1
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$login_keychain" "$certificate_file"

identity_hash="$(/usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/awk -v name="\"$identity_name\"" 'index($0, name) {print $2; exit}')"
[[ "$identity_hash" =~ '^[0-9A-Fa-f]{40}$' ]] || {
    print -u2 -- "憑證已匯入，但尚未成為有效 Code Signing 身分；請檢查 Keychain 信任設定。"
    exit 1
}

MYTERM_CODE_SIGN_IDENTITY="$identity_hash" \
    "$project_dir/scripts/stage-code-signing-baseline.sh" --identity "$identity_hash"
/bin/mv -- "$partial_destination" "$destination"
/bin/chmod 0600 "$destination"
identity_finalized=1

print -r -- "固定簽署身分與加密備份已建立。"
print -r -- "備份：$destination"
print -r -- "備份 SHA-256：$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')"
print -r -- "下一步請執行 verify-code-signing-key-backup.sh 做隔離還原簽署驗證。"
