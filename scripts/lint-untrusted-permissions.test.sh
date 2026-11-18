#!/usr/bin/env bash
# Positive and negative cases for lint-untrusted-permissions.py. Each negative
# case plants one violation in a copy of the repository files and expects the
# lint to fail with a matching message. Copies are created with mktemp and left
# in place.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="${PYTHON:-python3}"
LINT="$SCRIPT_DIR/lint-untrusted-permissions.py"
WORK="$(mktemp -d)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

"$PY" "$LINT" --root "$ROOT" > "$WORK/positive.log" 2>&1 || {
  cat "$WORK/positive.log" >&2
  fail "lint rejected the real workflow"
}
echo "positive: $(cat "$WORK/positive.log")"

# new_case <name>: creates $WORK/<name> with copies of actions/ and the workflows.
new_case() {
  local dir="$WORK/$1"
  mkdir -p "$dir/.github/workflows"
  cp -R "$ROOT/actions" "$dir/actions"
  cp "$ROOT/.github/workflows/build-images.yaml" "$dir/.github/workflows/"
  cp "$ROOT/.github/workflows/build-images-selftest.yaml" "$dir/.github/workflows/"
  cp "$ROOT/.github/workflows/plan-images-test.yaml" "$dir/.github/workflows/"
  echo "$dir"
}

# expect_fail <name> <expected message substring>
expect_fail() {
  local name="$1" expected="$2" dir
  dir="$(new_case "$name")"
  "$PY" - "$dir" "$name" <<'PY'
import sys
root, name = sys.argv[1], sys.argv[2]
wf = f"{root}/.github/workflows/build-images.yaml"
text = open(wf, encoding="utf-8").read()

def mutate(old, new):
    global text
    if text.count(old) != 1:
        raise SystemExit(f"mutation anchor not unique for {name}")
    text = text.replace(old, new)

if name == "planted_job":
    text += (
        "  leak:\n"
        "    runs-on: ubuntu-24.04\n"
        "    permissions:\n"
        "      contents: read\n"
        "      id-token: write\n"
        "    steps:\n"
        "      - run: echo hi\n"
    )
elif name == "login_in_composite":
    path = f"{root}/actions/build-image/action.yml"
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(
            "    - name: Login\n"
            "      uses: docker/login-action@650006c6eb7dba73a995cc03b0b2d7f5ca915bee # v4.2.0\n"
        )
elif name == "environment_on_untrusted":
    mutate("  build:\n    name: build (${{ matrix.image }}, ${{ matrix.builder }})\n",
           "  build:\n    name: build (${{ matrix.image }}, ${{ matrix.builder }})\n    environment: release\n")
elif name == "unpinned_uses":
    text = text.replace("actions/checkout@71cf2267d89c5cb81562390fa70a37fa40b1305e # v6",
                        "actions/checkout@v6", 1)
elif name == "latest_in_action":
    path = f"{root}/actions/smoke-test/action.yml"
    with open(path, encoding="utf-8") as handle:
        content = handle.read()
    content = content.replace("name: 'Smoke test'", "name: 'Smoke test (ghcr.io/example/tool:latest)'", 1)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)
elif name == "workflow_permissions":
    mutate("name: Build images (Reusable)\n", "name: Build images (Reusable)\n\npermissions:\n  contents: write\n")
elif name == "secrets_in_result":
    mutate("          PLAN_RESULT: ${{ needs.plan.result }}\n",
           "          PLAN_RESULT: ${{ needs.plan.result }}\n          TOKEN: ${{ secrets.TOKEN }}\n")
elif name == "selftest_caller_read_only":
    selftest = f"{root}/.github/workflows/build-images-selftest.yaml"
    text_st = open(selftest, encoding="utf-8").read()
    text_st = text_st.replace("      id-token: write\n      attestations: write\n", "", 1)
    open(selftest, "w", encoding="utf-8").write(text_st)
elif name == "privileged_without_trusted_if":
    mutate("    if: ${{ always() && needs.plan.outputs.trusted == 'true' && needs.plan.outputs.has_manifest == 'true' && needs.publish.result == 'success' }}",
           "    if: ${{ always() && needs.plan.outputs.has_manifest == 'true' }}")
else:
    raise SystemExit(f"unknown case {name}")
open(wf, "w", encoding="utf-8").write(text)
PY
  set +e
  "$PY" "$LINT" --root "$dir" > "$dir.log" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    cat "$dir.log" >&2
    fail "$name: lint passed but should have failed"
  fi
  if ! grep -q -- "$expected" "$dir.log"; then
    cat "$dir.log" >&2
    fail "$name: expected message containing: $expected"
  fi
  echo "negative $name: rejected ($expected)"
}

expect_fail planted_job "job leak"
expect_fail login_in_composite "docker/login-action"
expect_fail environment_on_untrusted "unprivileged job must not declare an environment"
expect_fail unpinned_uses "not pinned to a 40-hex SHA"
expect_fail latest_in_action ":latest"
expect_fail workflow_permissions "workflow-level permissions"
expect_fail secrets_in_result "references secrets"
expect_fail selftest_caller_read_only "must grant exactly"
expect_fail privileged_without_trusted_if "unprivileged job must not declare an environment"

echo "lint self-tests passed"
