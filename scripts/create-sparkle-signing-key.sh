#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source "$project_dir/scripts/sparkle-key-common.sh"
generate_keys="$(find_sparkle_tool "$project_dir" generate_keys)"
public_key_file="$project_dir/Config/Release/SparklePublicKey.txt"

mkdir -p "${public_key_file:h}"
public_output="$("$generate_keys" --account "$MYTERM_SPARKLE_KEY_ACCOUNT")"
public_key="$(print -r -- "$public_output" | /usr/bin/grep -Eo '[A-Za-z0-9+/]{43}=' | /usr/bin/tail -1)"

if [[ -z "$public_key" ]]; then
    print -u2 -- "Sparkle 沒有回傳可辨識的 Ed25519 公鑰，停止寫入設定。"
    exit 1
fi
decoded_size="$(print -rn -- "$public_key" | /usr/bin/base64 -D | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
if [[ "$decoded_size" != "32" ]]; then
    print -u2 -- "Sparkle 公鑰不是預期的 32 bytes，停止寫入設定。"
    exit 1
fi
if [[ -f "$public_key_file" && "$(<"$public_key_file")" != "$public_key" ]]; then
    print -u2 -- "專案內已有不同的 Sparkle 公鑰，拒絕覆蓋。"
    exit 1
fi

umask 022
print -rn -- "$public_key" > "$public_key_file"
chmod 0644 "$public_key_file"
fingerprint="$(print -rn -- "$public_key" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"

print -r -- "Sparkle 正式簽章金鑰已存在於登入 Keychain。"
print -r -- "Keychain account：$MYTERM_SPARKLE_KEY_ACCOUNT"
print -r -- "公鑰 SHA-256：$fingerprint"
print -r -- "公鑰已寫入：$public_key_file"
print -r -- "下一步必須建立兩份加密備份；請勿把私鑰內容貼到對話或提交到 Git。"
