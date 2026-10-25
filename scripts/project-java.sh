#!/bin/bash
# Select the project JDK; never alter global JAVA_HOME or the system installation.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" == Darwin ]]; then
  java_home="$("$project_dir/scripts/project-python.sh" -B "$project_dir/scripts/project-java-runtime.py" verify)"
else
  # CI runtime evidence is collected independently; a Mac result cannot bless it.
  java_bin="$(command -v java || true)"
  [[ -n "$java_bin" ]] || { echo "A reviewed Java 21 runtime is required." >&2; exit 69; }
  java_bin="$(readlink -f "$java_bin")"
  java_home="$(dirname "$(dirname "$java_bin")")"
fi
if [[ "${1:-}" == --print-home ]]; then
  printf '%s\n' "$java_home"
  exit 0
fi
unset JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS
export JAVA_HOME="$java_home"
exec "$java_home/bin/java" "$@"
