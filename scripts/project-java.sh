#!/bin/bash
# Select the project JDK; never alter global JAVA_HOME or the system installation.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
java_home="$("$project_dir/scripts/project-python.sh" -B "$project_dir/scripts/project-java-runtime.py" verify)"
if [[ "${1:-}" == --print-home ]]; then
  printf '%s\n' "$java_home"
  exit 0
fi
unset JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS
export JAVA_HOME="$java_home"
exec "$java_home/bin/java" "$@"
