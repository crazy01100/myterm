#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="${MYTERM_SECURITY_PYTHON_BOOTSTRAP:-python3}"
"$python_bin" -c 'import sys; assert sys.version_info >= (3, 9, 2), "Python >=3.9.2 required"'
venv="$project_dir/.build/security-tools"
"$python_bin" -m venv "$venv"
"$venv/bin/python3" -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: -r "$project_dir/Tests/Security/requirements.txt"
"$venv/bin/python3" -c 'from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey'
echo "Security tools ready. No signing key is needed."
