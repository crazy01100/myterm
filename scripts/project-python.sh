#!/bin/bash
# Select a supported project interpreter without replacing the system Python.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
usable() {
  [[ -x "$1" ]] && "$1" -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) and sys.version_info.releaselevel == "final" else 1)' >/dev/null 2>&1
}
if [[ -n "${MYTERM_PYTHON:-}" ]]; then
  python_bin="$(command -v "$MYTERM_PYTHON" || true)"
  if ! usable "$python_bin"; then
    echo "MYTERM_PYTHON must select a stable Python >=3.12 interpreter." >&2
    exit 69
  fi
else
  python_bin=""
  candidates=("$project_dir/.build/python-runtime/bin/python3")
  for name in python3 python3.14 python3.13 python3.12; do
    found="$(command -v "$name" || true)"
    [[ -z "$found" ]] || candidates+=("$found")
  done
  for candidate in "${candidates[@]}"; do
    if usable "$candidate"; then python_bin="$candidate"; break; fi
  done
  if [[ -z "$python_bin" ]]; then
    echo "Python >=3.12 is required. Install a supported Python, set MYTERM_PYTHON to its executable, or create .build/python-runtime with it. See DEVELOPMENT.md." >&2
    exit 69
  fi
fi
exec "$python_bin" "$@"
