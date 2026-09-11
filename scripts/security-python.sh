#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="$project_dir/.build/security-tools/bin/python3"
[[ -x "$python_bin" ]] || { echo "Run scripts/setup-security-tools.sh before security verification." >&2; exit 69; }
exec "$python_bin" "$@"
