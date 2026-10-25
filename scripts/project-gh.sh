#!/bin/bash
# Always select the verified project CLI; never fall back to PATH's gh.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
gh_bin="$("$project_dir/scripts/project-python.sh" -I -B "$project_dir/scripts/project-gh-runtime.py" verify)"
exec "$gh_bin" "$@"
