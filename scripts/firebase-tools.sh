#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
firebase_cli="$project_root/node_modules/.bin/firebase"
"$project_root/scripts/project-python.sh" "$project_root/scripts/firebase-command-policy.py" "$@"
cd "$project_root"

export FIREBASE_EMULATORS_PATH="$project_root/.firebase/emulators"
export XDG_CONFIG_HOME="$project_root/.firebase/config"
export npm_config_cache="$project_root/.npm-cache"

if [[ ! -x "$firebase_cli" ]]; then
  print -u2 "尚未安裝 Firebase 開發工具。請先在專案根目錄執行：npm_config_cache=.npm-cache npm install"
  exit 1
fi

# Refuse an incomplete install or upstream drift before loading CLI commands.
"$project_root/scripts/project-python.sh" "$project_root/scripts/patch-firebase-stream-json.py" --check >/dev/null

# Homebrew 在 Apple Silicon 的標準位置是 /opt/homebrew；這台 Mac 目前的
# 既有 Homebrew 位於 /usr/local。兩者都檢查，避免要求使用者修改全域 PATH。
for java_home_candidate in \
  /opt/homebrew/opt/openjdk@21 \
  /usr/local/opt/openjdk@21
do
  if [[ -x "$java_home_candidate/bin/java" ]]; then
    export JAVA_HOME="$java_home_candidate"
    export PATH="$JAVA_HOME/bin:$PATH"
    break
  fi
done

exec "$project_root/scripts/project-node.sh" "$firebase_cli" "$@"
