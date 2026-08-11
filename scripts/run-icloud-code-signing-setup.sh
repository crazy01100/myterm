#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
backup_root="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
backup_dir="$backup_root/MyTerm 安全備份"
backup_file="$backup_dir/MyTerm-Code-Signing-Backup.dmg"

[[ -d "$backup_root" ]] || {
    print -u2 -- "找不到 iCloud Drive。請先在這台 Mac 啟用 iCloud Drive。"
    exit 69
}
/bin/mkdir -p -- "$backup_dir"
"$project_dir/scripts/initialize-local-code-signing-identity.sh" "$backup_file"
"$project_dir/scripts/verify-code-signing-key-backup.sh" "$backup_file"

print -r -- "MyTerm 固定 Code Signing 身分、iCloud 加密備份與隔離還原驗證已完成。"
