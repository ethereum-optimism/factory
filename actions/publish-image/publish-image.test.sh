#!/usr/bin/env bash
# Renders the bake overrides that publish-image passes to docker/bake-action for
# a bake-mode image, then checks that docker buildx bake accepts them against
# the self-test fixture. Requires docker with buildx, and jq.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION="${PUBLISH_ACTION:-$ROOT/actions/publish-image/action.yml}"
BAKE_FILE="test/fixtures/bake/docker-bake.hcl"
TARGET="selftest-bake"
WORK="$(mktemp -d)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

awk '
  /name: Push architecture with docker bake/ { in_step = 1 }
  in_step && /^        set: \|/ { in_set = 1; next }
  in_set && /^    - name:/ { exit }
  in_set && /^          / { sub(/^          /, ""); print }
' "$ACTION" > "$WORK/set.template"
[ -s "$WORK/set.template" ] || fail "no bake set block found in $ACTION"

sed \
  -e 's|\${{ inputs.arch }}|amd64|g' \
  -e 's|\${{ inputs.image }}|selftest-bake|g' \
  -e 's|\${{ inputs.registry }}|registry.invalid/selftest|g' \
  -e '/^\${{ inputs.set }}$/d' \
  "$WORK/set.template" > "$WORK/overrides.txt"
if grep -q -F "\${{" "$WORK/overrides.txt"; then
  cat "$WORK/overrides.txt" >&2
  fail "unrendered expression in overrides"
fi

args=()
while IFS= read -r line; do
  [ -n "$line" ] && args+=(--set "$line")
done < "$WORK/overrides.txt"

cd "$ROOT"
if ! docker buildx bake --print -f "$BAKE_FILE" "$TARGET" "${args[@]}" > "$WORK/print.json" 2> "$WORK/print.err"; then
  cat "$WORK/print.err" >&2
  fail "bake rejected the publish overrides"
fi

jq -e --arg t "$TARGET" '
  .target[$t].attest | map(.type) | sort == ["provenance", "sbom"]
' "$WORK/print.json" > /dev/null || fail "attestations missing from bake definition"
jq -e --arg t "$TARGET" '
  .target[$t].output[0]["push-by-digest"] == "true"
' "$WORK/print.json" > /dev/null || fail "output is not push-by-digest"
jq -e --arg t "$TARGET" '
  (.target[$t].tags // []) | length == 0
' "$WORK/print.json" > /dev/null || fail "publish overrides left file tags on the target"

echo "publish-image bake overrides accepted by bake:"
sed 's/^/  --set /' "$WORK/overrides.txt"
