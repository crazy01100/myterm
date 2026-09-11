#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="$project_dir/.build/security-tools/bin/python3"
[[ -x "$python_bin" ]] || { echo "Run scripts/setup-security-tools.sh before security verification." >&2; exit 69; }
"$python_bin" -I -c 'import sys; assert sys.version_info >= (3, 12), "Recreate security tools with Python >=3.12"'
exec "$python_bin" "$@"
