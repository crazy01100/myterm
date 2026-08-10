#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source "$project_dir/scripts/sparkle-key-common.sh"

if (( $# != 1 )); then
    print -u2 -- "用法：scripts/initialize-sparkle-signing-key.sh /絕對路徑/MyTerm-Sparkle-Key-Backup.dmg"
    exit 64
fi

destination="$1"
validate_sparkle_backup_destination "$project_dir" "$destination"

print -r -- "MyTerm 將建立正式 Sparkle 更新簽章金鑰。"
print -r -- "私鑰只會保存在登入 Keychain 與 AES-256 加密的 iCloud 備份。"
print -r -- "請依 macOS 提示設定備份密碼；不要把密碼貼到聊天或保存於 MyTerm 專案。"
print

"$project_dir/scripts/create-sparkle-signing-key.sh"
"$project_dir/scripts/backup-sparkle-signing-key.sh" "$destination"
"$project_dir/scripts/verify-sparkle-key-backup.sh" "$destination"

print
print -r -- "MyTerm Sparkle 正式金鑰初始化與 iCloud 備份驗證已完成。"
print -r -- "備份位置：$destination"
