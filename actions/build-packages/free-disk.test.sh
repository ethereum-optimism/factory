#!/usr/bin/env bash
# Tests for free-disk.sh against a temporary directory tree.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FREE_DISK="$SCRIPT_DIR/free-disk.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TEST_DIR/tree/a/deep" "$TEST_DIR/tree/b"
: > "$TEST_DIR/tree/a/deep/file"
: > "$TEST_DIR/tree/b/file"

env FREE_DISK_SUDO='' bash "$FREE_DISK" "$TEST_DIR/tree/a" "$TEST_DIR/tree/missing" > "$TEST_DIR/out" \
  || fail "script failed with a missing path"
[[ ! -e "$TEST_DIR/tree/a" ]] || fail "existing path was not removed"
[[ -e "$TEST_DIR/tree/b/file" ]] || fail "unrelated path was removed"
grep -q "skipping missing $TEST_DIR/tree/missing" "$TEST_DIR/out" || fail "missing path was not reported"
grep -q "disk usage after:" "$TEST_DIR/out" || fail "disk usage was not printed"

echo "free-disk tests passed"
