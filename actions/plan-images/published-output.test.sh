#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
yq -r '.jobs.published.steps[] | select(.id == "list") | .run' "$ROOT/.github/workflows/build-images.yaml" > "$WORK/list.sh"
[ -s "$WORK/list.sh" ] || { echo "FAIL: no list step in the published job" >&2; exit 1; }

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

D1="sha256:$(printf '1%.0s' $(seq 1 64))"
D2="sha256:$(printf '2%.0s' $(seq 1 64))"
D3="sha256:$(printf '3%.0s' $(seq 1 64))"
mkdir -p "$WORK/final"
printf '%s\n' "$D1" > "$WORK/final/geth-v1-17-apko.txt"
printf '%s\n' "$D2" > "$WORK/final/plain-docker.txt"
printf '%s\n' "$D3" > "$WORK/final/tool-ko.txt"

PUBLISH='[
  {"id": "geth-v1-17-apko", "image": "geth-v1-17", "kind": "apko", "registry": "r.invalid/images", "repository": "group/geth", "sha_tag": "v1.17-20261127-0123456789ab"},
  {"id": "plain-docker-amd64", "image": "plain", "kind": "docker-arch", "registry": "r.invalid/images", "repository": "plain", "sha_tag": "abc"},
  {"id": "tool-ko", "image": "tool", "kind": "ko", "registry": "r.invalid/images", "repository": "tool", "sha_tag": "abc"},
  {"id": "failed-apko", "image": "failed", "kind": "apko", "registry": "r.invalid/images", "repository": "failed", "sha_tag": "abc"}
]'
MANIFEST='[{"id": "plain-docker", "image": "plain", "registry": "r.invalid/images", "repository": "plain", "sha_tag": "abc"}]'

run_list() {
  local name="$1" dir="$2"
  : > "$WORK/$name.out"
  env PUBLISH_MATRIX="$PUBLISH" MANIFEST_MATRIX="$MANIFEST" FINAL_DIR="$dir" GITHUB_OUTPUT="$WORK/$name.out" \
    bash "$WORK/list.sh" > "$WORK/$name.log" 2>&1
}

run_list full "$WORK/final" || fail "list failed: $(cat "$WORK/full.log")"
images="$(sed -n 's/^images=//p' "$WORK/full.out")"
[ "$(jq -r 'map(.id) | join(",")' <<< "$images")" = "geth-v1-17-apko,plain-docker,tool-ko" ] || fail "unexpected ids: $images"
[ "$(jq -r '.[0] | "\(.image) \(.name) \(.ref) \(.digest)"' <<< "$images")" = "geth-v1-17 r.invalid/images/group/geth r.invalid/images/group/geth:v1.17-20261127-0123456789ab $D1" ] \
  || fail "unexpected entry: $images"
[ "$(jq -r '.[1].digest' <<< "$images")" = "$D2" ] || fail "manifest digest missing: $images"
grep -q -F "r.invalid/images/tool:abc@$D3" "$WORK/full.log" || fail "log does not list the published reference"

run_list none "$WORK/missing" || fail "list failed without digests"
[ "$(sed -n 's/^images=//p' "$WORK/none.out")" = "[]" ] || fail "no digests did not give an empty list"

mkdir -p "$WORK/bad"
printf 'sha256:abc\n' > "$WORK/bad/tool-ko.txt"
if run_list bad "$WORK/bad"; then
  fail "an invalid digest was accepted"
fi

echo "published output tests passed"
