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
  -e 's/\${{ inputs.repository || inputs.image }}/selftest-bake/g' \
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

if grep -q 'docker/login-action' "$ACTION"; then
  fail "publish-image logs in with a static token instead of the credential helper"
fi
if grep -q 'registry_token' "$ACTION"; then
  fail "publish-image still takes a static registry token input"
fi
grep -q -F "configure-docker \"\${REGISTRY%%/*}\" --quiet" "$ACTION" \
  || fail "credential helper is not configured for the registry host"
grep -q -F "export APKO_GENERIC_PASS=\"\$token\"" "$ACTION" \
  || fail "apko login does not mint its token immediately before the sandbox starts"

REFRESH="$ROOT/actions/publish-image/refresh-attest-auth.sh"
[ -x "$REFRESH" ] || fail "missing $REFRESH"
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gcloud" <<'FAKE'
#!/usr/bin/env bash
echo "fake-token-123"
FAKE
chmod +x "$FAKE_BIN/gcloud"
CONFIG="$WORK/docker/config.json"
mkdir -p "$(dirname "$CONFIG")"
echo '{"credHelpers":{"us-docker.pkg.dev":"gcloud"},"auths":{"other.example":{"auth":"eA=="}}}' > "$CONFIG"
PATH="$FAKE_BIN:$PATH" REGISTRY="us-docker.pkg.dev/proj/repo" DOCKER_CONFIG_FILE="$CONFIG" \
  bash "$REFRESH" > /dev/null
jq -e '.credHelpers["us-docker.pkg.dev"] == "gcloud"' "$CONFIG" > /dev/null \
  || fail "refresh dropped the credential helper entry"
jq -e '.auths["other.example"].auth == "eA=="' "$CONFIG" > /dev/null \
  || fail "refresh dropped an unrelated auths entry"
expected_auth="$(printf 'oauth2accesstoken:fake-token-123' | base64 | tr -d '\n')"
jq -e --arg a "$expected_auth" '.auths["us-docker.pkg.dev"].auth == $a' "$CONFIG" > /dev/null \
  || fail "refresh did not write the registry host auths entry"

grep -q -F "KO_ALIAS_TAGS" "$ACTION" \
  || fail "alias tags are not passed to the ko publish path"
grep -q -F "APKO_ALIAS_TAGS" "$ACTION" \
  || fail "alias tags are not passed to the apko publish path"
grep -q -F "tag_args+=(-t \"\${name}:\${alias_tag}\")" "$ACTION" \
  || fail "alias tags are not added to the manifest list tags"

echo "publish-image registry auth: credential helper, apko token and attest refresh checks passed"
