#!/bin/zsh

MYTERM_SPARKLE_KEY_ACCOUNT="MyTerm.Release.ed25519"
MYTERM_SPARKLE_KEY_SERVICE="https://sparkle-project.org"
MYTERM_SPARKLE_PRIVATE_KEY_FILENAME="MyTerm-Sparkle-Private-Key.txt"
MYTERM_SPARKLE_BACKUP_MANIFEST="MyTerm-Sparkle-Key-Backup.txt"

find_sparkle_tool() {
    local project_dir="$1"
    local tool_name="$2"
    local candidate
    local candidates=(
        "$project_dir"/.build/artifacts/**/bin/"$tool_name"(N)
        "$project_dir"/.build-app/artifacts/**/bin/"$tool_name"(N)
    )

    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            print -r -- "$candidate"
            return 0
        fi
    done

    print -u2 -- "找不到 Sparkle 工具 $tool_name；請先執行一次正式候選建置。"
    return 1
}

validate_sparkle_backup_destination() {
    local project_dir="$1"
    local destination="$2"

    if [[ "$destination" != /* || "${destination:e}" != "dmg" ]]; then
        print -u2 -- "備份路徑必須是絕對路徑，且副檔名必須是 .dmg：$destination"
        return 64
    fi
    if [[ -e "$destination" ]]; then
        print -u2 -- "目的檔案已存在，為避免覆蓋而停止：$destination"
        return 65
    fi

    local parent="${destination:h:A}"
    local resolved_project="${project_dir:A}"
    if [[ ! -d "$parent" || ! -w "$parent" ]]; then
        print -u2 -- "目的資料夾不存在或無法寫入：$parent"
        return 66
    fi
    if [[ "$parent" == "$resolved_project" || "$parent" == "$resolved_project"/* ]]; then
        print -u2 -- "私鑰備份不可放在 MyTerm 專案目錄內。"
        return 66
    fi
    if [[ "$parent" == /tmp || "$parent" == /tmp/* || "$parent" == /private/tmp || "$parent" == /private/tmp/* ]]; then
        print -u2 -- "私鑰備份不可放在暫存目錄。"
        return 66
    fi
}

read_sparkle_public_key() {
    local generate_keys="$1"
    "$generate_keys" --account "$MYTERM_SPARKLE_KEY_ACCOUNT" -p
}
