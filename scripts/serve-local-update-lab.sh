#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
feed_dir="$project_dir/build/update-lab/feed"
port="${MYTERM_UPDATE_LAB_PORT:-48123}"

[[ -f "$feed_dir/appcast.xml" ]] || {
    print -u2 -- "本機更新實驗室尚未建立；請先執行 prepare-local-update-lab.sh。"
    exit 66
}

print -r -- "MyTerm 本機更新 feed：http://127.0.0.1:$port/appcast.xml"
print -r -- "保持這個程序執行，直到 beta.1 → beta.2 測試完成。"
exec /usr/bin/python3 -m http.server "$port" --bind 127.0.0.1 --directory "$feed_dir"
