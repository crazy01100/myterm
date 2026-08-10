#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
backup_dir="$HOME/Library/Mobile Documents/com~apple~CloudDocs/MyTerm 安全備份"
backup_file="$backup_dir/MyTerm-Sparkle-Key-Backup.dmg"

if [[ ! -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ]]; then
    print -u2 -- "找不到 iCloud Drive。請先在這台 Mac 啟用 iCloud Drive，再重新執行。"
    exit 69
fi

/bin/mkdir -p -- "$backup_dir"
exec "$project_dir/scripts/initialize-sparkle-signing-key.sh" "$backup_file"
