#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source "$project_dir/scripts/sparkle-key-common.sh"

if (( $# != 1 )); then
    print -u2 -- "用法：scripts/backup-sparkle-signing-key.sh /絕對路徑/MyTerm-Sparkle-Key-Backup.dmg"
    exit 64
fi

destination="$1"
validate_sparkle_backup_destination "$project_dir" "$destination"
generate_keys="$(find_sparkle_tool "$project_dir" generate_keys)"
public_key="$(read_sparkle_public_key "$generate_keys")"
public_fingerprint="$(print -rn -- "$public_key" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
work_dir="$(mktemp -d /private/tmp/MyTerm-Sparkle-backup.XXXXXX)"
partial_destination="${destination:r}.partial.dmg"

cleanup() {
    if [[ -f "$work_dir/payload/$MYTERM_SPARKLE_PRIVATE_KEY_FILENAME" ]]; then
        /bin/rm -P -- "$work_dir/payload/$MYTERM_SPARKLE_PRIVATE_KEY_FILENAME" 2>/dev/null || true
    fi
    /bin/rm -rf -- "$work_dir"
    /bin/rm -f -- "$partial_destination"
}
trap cleanup EXIT INT TERM

umask 077
mkdir -p "$work_dir/payload"
private_key_file="$work_dir/payload/$MYTERM_SPARKLE_PRIVATE_KEY_FILENAME"
"$generate_keys" --account "$MYTERM_SPARKLE_KEY_ACCOUNT" -x "$private_key_file"
chmod 0600 "$private_key_file"

cat > "$work_dir/payload/$MYTERM_SPARKLE_BACKUP_MANIFEST" <<EOF
MyTerm Sparkle 更新簽章金鑰備份
建立時間：$(date '+%Y-%m-%d %H:%M:%S %z')
Sparkle Keychain account：$MYTERM_SPARKLE_KEY_ACCOUNT
SUPublicEDKey：$public_key
公鑰 SHA-256：$public_fingerprint

這是正式更新信任根的 AES-256 加密備份。
不要把私鑰檔案、磁碟映像密碼或解密後內容傳送到聊天、Git、Cloudflare、Firebase 或 GitHub Release。
請使用 MyTerm 專案的 verify-sparkle-key-backup.sh 做真實還原簽署測試。
EOF
chmod 0600 "$work_dir/payload/$MYTERM_SPARKLE_BACKUP_MANIFEST"

print -r -- "macOS 接下來會要求你設定這份備份專用密碼。請勿在對話中提供密碼。"
/usr/bin/hdiutil create -quiet \
    -encryption AES-256 \
    -format UDZO \
    -volname "MyTerm Sparkle Key Backup" \
    -srcfolder "$work_dir/payload" \
    "$partial_destination"
/usr/bin/hdiutil verify "$partial_destination" >/dev/null
/bin/mv -- "$partial_destination" "$destination"
chmod 0600 "$destination"

backup_digest="$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')"
print -r -- "加密備份已建立：$destination"
print -r -- "備份 SHA-256：$backup_digest"
print -r -- "公鑰 SHA-256：$public_fingerprint"
