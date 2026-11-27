#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-packages.sh"
WORK="$(mktemp -d)"
A="sha256:$(printf 'a%.0s' {1..64})"
B="sha256:$(printf 'b%.0s' {1..64})"
C="sha256:$(printf 'c%.0s' {1..64})"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cat > "$WORK/lock.json" <<JSON
{"contents": {"packages": [
  {"name": "base", "version": "1-r0", "architecture": "x86_64", "url": "https://apk.example.dev/org/x86_64/base-1-r0.apk", "sha256": "$C"},
  {"name": "tool", "version": "1-r0", "architecture": "x86_64", "local": true},
  {"name": "tool", "version": "1-r0", "architecture": "aarch64", "local": true},
  {"name": "armonly", "version": "1-r0", "architecture": "aarch64", "local": true}
]}}
JSON
mkdir -p "$WORK/digests"
printf 'tool=%s\nother=%s\n' "$A" "$C" > "$WORK/digests/tool-x86_64.txt"
printf 'tool=%s\narmonly=%s\n' "$B" "$C" > "$WORK/digests/tool-aarch64.txt"

out="$("$SCRIPT" "$WORK/lock.json" "$WORK/digests" amd64)"
[ "$out" = "tool=$A
tool=$B" ] || fail "amd64 output: $out"

out="$("$SCRIPT" "$WORK/lock.json" "$WORK/digests" amd64,arm64)"
[ "$(printf '%s\n' "$out" | sort | paste -sd' ' -)" = "armonly=$C tool=$A tool=$B" ] || fail "multi-arch output: $out"

rm "$WORK/digests/tool-aarch64.txt"
if "$SCRIPT" "$WORK/lock.json" "$WORK/digests" arm64 > "$WORK/missing.log" 2>&1; then
  fail "a local package without a digest was accepted"
fi
grep -q 'built in no package leg of this run: armonly' "$WORK/missing.log" || fail "missing digest message: $(cat "$WORK/missing.log")"

if "$SCRIPT" "$WORK/lock.json" "" amd64 > "$WORK/nodir.log" 2>&1; then
  fail "a lock with local packages was accepted without digests"
fi

printf '{"contents": {"packages": [{"name": "base", "architecture": "x86_64", "url": "u", "sha256": "%s"}]}}' "$C" > "$WORK/remote.json"
[ -z "$("$SCRIPT" "$WORK/remote.json" "" amd64)" ] || fail "a lock without local packages printed digests"

echo "local-packages tests passed"
