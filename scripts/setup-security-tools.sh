#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="$project_dir/scripts/project-python.sh"
if [[ -n "${MYTERM_SECURITY_PYTHON_BOOTSTRAP:-}" ]]; then
  export MYTERM_PYTHON="$MYTERM_SECURITY_PYTHON_BOOTSTRAP"
fi
# Prepare and verify pinned wheels before creating/updating project-owned venvs.
"$python_bin" -B "$project_dir/scripts/python-toolchain.py" setup
venv="$project_dir/.build/security-tools"
PIP_CONFIG_FILE=/dev/null "$project_dir/scripts/security-python.sh" -I -m pip --isolated install --index-url https://pypi.org/simple --no-cache-dir --disable-pip-version-check --require-hashes --only-binary=:all: -r "$project_dir/Tests/Security/requirements.txt"
"$project_dir/scripts/security-python.sh" -I -c 'from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey'
echo "Security tools ready. No signing key is needed."
