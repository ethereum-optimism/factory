#!/usr/bin/env bash
# Tests for resolve-build-root.sh against a temporary workspace layout.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESOLVE="$SCRIPT_DIR/resolve-build-root.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WS="$TEST_DIR/workspace"
mkdir -p "$WS/.package-sources/tool/pipelines" "$WS/pipelines" "$WS/melange" "$WS/tools/src"
: > "$WS/.package-sources/tool/melange-tool.yaml"
WS_REAL=$(cd "$WS" && pwd -P)

# expect_root <build_dir> <expected absolute path>
expect_root() {
  local got
  got=$(bash "$RESOLVE" "$WS" "$1") || fail "resolver rejected '$1'"
  [[ "$got" == "$2" ]] || fail "build_dir '$1': expected '$2', got '$got'"
}

# expect_reject <build_dir>
expect_reject() {
  if bash "$RESOLVE" "$WS" "$1" > /dev/null 2> "$TEST_DIR/err"; then
    fail "resolver accepted '$1'"
  fi
}

expect_root "." "$WS_REAL"
expect_root "" "$WS_REAL"
expect_root "tools" "$WS_REAL/tools"
expect_root "tools/src/" "$WS_REAL/tools/src"
expect_root ".package-sources/tool" "$WS_REAL/.package-sources/tool"

expect_reject "../outside"
expect_reject "tools/../../outside"
expect_reject "/abs"
expect_reject "tools/../tools"
expect_reject "missing"
expect_reject "has space"

echo "resolve-build-root tests passed"
