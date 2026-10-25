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
  print -u2 "尚未安裝 Firebase 開發工具。請先使用專案 Node 入口完成固定相依安裝，詳見 DEVELOPMENT.md。"
  exit 1
fi

# Refuse stale or incomplete installations before loading CLI commands.
"$project_root/scripts/project-python.sh" "$project_root/scripts/security-source-review.py" --purpose firebase --task "${MYTERM_RISK_TASK:-firebase-wrapper}"

"$project_root/scripts/project-node.sh" "$project_root/scripts/verify-firebase-tools.cjs" >/dev/null

export JAVA_HOME="$("$project_root/scripts/project-java.sh" --print-home)"
export PATH="$JAVA_HOME/bin:$PATH"
unset JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS

exec "$project_root/scripts/project-node.sh" "$firebase_cli" "$@"
