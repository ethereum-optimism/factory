#!/usr/bin/env bash
# Runs scripts/lint-untrusted-permissions.py with the repository's own actions.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${PYTHON:-python3}" "$SCRIPT_DIR/lint-untrusted-permissions.py" "$@"
