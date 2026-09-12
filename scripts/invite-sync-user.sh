#!/bin/bash
# Administrator-only entry point; never bundled into MyTerm.
set -euo pipefail
umask 077
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
exec "$project_dir/scripts/project-node.sh" "$project_dir/scripts/invite-sync-user.mjs" "$@"
