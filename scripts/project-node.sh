#!/bin/bash
# Keep project Node/npm on the reviewed Node 24 LTS line.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
usable() {
  [[ -x "$1" ]] && "$1" -e 'process.exit(/^24\./.test(process.versions.node) ? 0 : 1)' >/dev/null 2>&1
}
if [[ -n "${MYTERM_NODE:-}" ]]; then
  node_bin="$(command -v "$MYTERM_NODE" || true)"
  if ! usable "$node_bin"; then echo "MYTERM_NODE must select Node 24 LTS." >&2; exit 69; fi
else
  node_bin=""
  for candidate in "$project_dir/.build/node-runtime/bin/node" "$(command -v node || true)" /opt/homebrew/opt/node@24/bin/node /usr/local/opt/node@24/bin/node; do
    if usable "$candidate"; then node_bin="$candidate"; break; fi
  done
  if [[ -z "$node_bin" ]]; then echo "Node 24 LTS is required. Install it, set MYTERM_NODE, or place its distribution at .build/node-runtime. See DEVELOPMENT.md." >&2; exit 69; fi
fi
export PATH="$(dirname "$node_bin"):$PATH"
if [[ "${1:-}" == "--npm" ]]; then
  shift
  npm_cli="$(dirname "$node_bin")/npm"
  [[ -f "$npm_cli" ]] || { echo "The selected Node distribution must include npm." >&2; exit 69; }
  exec "$node_bin" "$npm_cli" "$@"
fi
exec "$node_bin" "$@"
