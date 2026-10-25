#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="$project_dir/scripts/project-python.sh"
if [[ -n "${MYTERM_SECURITY_PYTHON_BOOTSTRAP:-}" ]]; then
  export MYTERM_PYTHON="$MYTERM_SECURITY_PYTHON_BOOTSTRAP"
fi
# Prepare and verify pinned wheels before creating/updating project-owned venvs.
"$python_bin" -B "$project_dir/scripts/python-toolchain.py" setup
"$project_dir/scripts/security-python.sh" -I -B "$project_dir/scripts/python-verifier-wheels.py" --output "$project_dir/.build/python-verifier-install.json"
"$project_dir/scripts/security-python.sh" -I -c 'from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey'
echo "Security tools ready. No signing key is needed."
