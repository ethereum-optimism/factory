#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

CONFIG="$TEST_DIR/catalog.json"
cat > "$CONFIG" <<'JSON'
{
  "melange_archs": ["x86_64"],
  "apko_archs": "amd64",
  "release": {
    "tag_regex": "^([^/]+)/(v.+)$",
    "service_match": 1,
    "version_match": 2,
    "publish_tag": "${version}",
    "source_ref": "${ref_name}"
  },
  "smoke_runners": {"amd64": "ubuntu-latest"},
  "melange": {"stack": {"config": "melange/stack.yaml"}},
  "images": {
    "widget": {
      "type": "go",
      "needs_melange": ["stack"],
      "verify_version": true,
      "smoke_test": "widget --version"
    },
    "gadget": {
      "type": "go",
      "needs_melange": ["stack"],
      "verify_version": true,
      "smoke_test": "gadget --version",
      "apko_configs": ["apko/gadget.yaml", "apko/gadget-dev.yaml"]
    }
  }
}
JSON

output_value() {
  local file="$1" key="$2"
  sed -n "s/^${key}=//p" "$file"
}

assert_json() {
  local json="$1" filter="$2" expected="$3"
  local actual
  actual=$(jq -r "$filter" <<< "$json")
  if [[ "$actual" != "$expected" ]]; then
    echo "assertion failed: $filter: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

release_output="$TEST_DIR/release.out"
GITHUB_EVENT_NAME=push \
GITHUB_REF_TYPE=tag \
GITHUB_REF_NAME=widget/v1.2.3 \
GITHUB_OUTPUT="$release_output" \
  "$SCRIPT_DIR/apko-plan.sh" "$CONFIG"

release_melange=$(output_value "$release_output" melange_matrix_json)
release_smoke=$(output_value "$release_output" smoke_matrix_json)
assert_json "$release_melange" '.[0].build_version' 'v1.2.3'
assert_json "$release_smoke" '.[0].expected_version' 'v1.2.3'
assert_json "$release_smoke" '.[0].smoke_test' 'widget --version'

branch_output="$TEST_DIR/branch.out"
GITHUB_EVENT_NAME=workflow_dispatch \
GITHUB_REF_TYPE=branch \
GITHUB_REF_NAME=main \
GITHUB_OUTPUT="$branch_output" \
  "$SCRIPT_DIR/apko-plan.sh" "$CONFIG"

branch_melange=$(output_value "$branch_output" melange_matrix_json)
branch_smoke=$(output_value "$branch_output" smoke_matrix_json)
assert_json "$branch_melange" '.[0].build_version' ''
assert_json "$branch_melange" '.[0].runner_profile' 'standard'
assert_json "$branch_melange" '.[0] | has("runner")' 'false'
assert_json "$branch_smoke" '.[0].expected_version' ''

invalid_output="$TEST_DIR/invalid.out"
GITHUB_EVENT_NAME=push \
GITHUB_REF_TYPE=tag \
GITHUB_REF_NAME=not-a-release \
GITHUB_OUTPUT="$invalid_output" \
  "$SCRIPT_DIR/apko-plan.sh" "$CONFIG"

assert_json "$(output_value "$invalid_output" apko_matrix_json)" 'length' '0'
if [[ "$(output_value "$invalid_output" is_release)" != "true" ]]; then
  echo "invalid release tag should still set is_release=true" >&2
  exit 1
fi

# Variant fan-out: an image with apko_configs publishes one apko row per config,
# deriving tag_suffix from the filename, without forking the melange build.
variant_output="$TEST_DIR/variant.out"
GITHUB_EVENT_NAME=push \
GITHUB_REF_TYPE=tag \
GITHUB_REF_NAME=gadget/v3.0.0 \
GITHUB_OUTPUT="$variant_output" \
  "$SCRIPT_DIR/apko-plan.sh" "$CONFIG"

variant_apko=$(output_value "$variant_output" apko_matrix_json)
variant_melange=$(output_value "$variant_output" melange_matrix_json)
variant_smoke=$(output_value "$variant_output" smoke_matrix_json)
# two apko rows: default + dev
assert_json "$variant_apko" 'length' '2'
assert_json "$variant_apko" '[.[].apko_config] | sort | join(",")' 'apko/gadget-dev.yaml,apko/gadget.yaml'
# default row: no suffix, keeps its smoke test
assert_json "$variant_apko" '[.[] | select(.tag_suffix == "")][0].apko_config' 'apko/gadget.yaml'
assert_json "$variant_apko" '[.[] | select(.tag_suffix == "")][0].smoke_test' 'gadget --version'
# dev row: -dev suffix, smoke suppressed (superset of default)
assert_json "$variant_apko" '[.[] | select(.tag_suffix == "-dev")][0].apko_config' 'apko/gadget-dev.yaml'
assert_json "$variant_apko" '[.[] | select(.tag_suffix == "-dev")][0].smoke_test' ''
# critical: the variant must NOT duplicate the melange build (one stack leg) or smoke (default only)
assert_json "$variant_melange" 'length' '1'
assert_json "$variant_smoke" 'length' '1'

# The default smoke runner must be able to run the built image. A runner
# without a docker daemon does not fail the job: `docker run` writes its error
# to the captured output and the loop only rejects a narrow set of exit codes,
# so every smoke test silently passes without the image ever starting.
default_runner_config="$TEST_DIR/default-runners.json"
jq 'del(.smoke_runners) | .apko_archs = "amd64,arm64"' "$CONFIG" > "$default_runner_config"

default_runner_output="$TEST_DIR/default-runners.out"
GITHUB_EVENT_NAME=workflow_dispatch \
GITHUB_REF_TYPE=branch \
GITHUB_REF_NAME=main \
GITHUB_OUTPUT="$default_runner_output" \
  "$SCRIPT_DIR/apko-plan.sh" "$default_runner_config"

default_runner_smoke=$(output_value "$default_runner_output" smoke_matrix_json)
assert_json "$default_runner_smoke" '[.[] | select(.arch == "amd64")][0].runner' 'ubuntu-24.04'
assert_json "$default_runner_smoke" '[.[] | select(.arch == "arm64")][0].runner' 'ubuntu-24.04-arm'

# An explicit smoke_runners entry still wins over the default, and an arch the
# override omits falls back to the default rather than to the overridden value.
partial_override_config="$TEST_DIR/partial-override.json"
jq '.smoke_runners = {"amd64": "ubuntu-latest"} | .apko_archs = "amd64,arm64"' \
  "$CONFIG" > "$partial_override_config"

partial_override_output="$TEST_DIR/partial-override.out"
GITHUB_EVENT_NAME=workflow_dispatch \
GITHUB_REF_TYPE=branch \
GITHUB_REF_NAME=main \
GITHUB_OUTPUT="$partial_override_output" \
  "$SCRIPT_DIR/apko-plan.sh" "$partial_override_config"

partial_override_smoke=$(output_value "$partial_override_output" smoke_matrix_json)
assert_json "$partial_override_smoke" '[.[] | select(.arch == "amd64")][0].runner' 'ubuntu-latest'
assert_json "$partial_override_smoke" '[.[] | select(.arch == "arm64")][0].runner' 'ubuntu-24.04-arm'

# Profile selection must preserve both build architectures and smoke output.
profile_config="$TEST_DIR/profiles.json"
jq '.melange_archs = ["x86_64", "aarch64"] | .melange.stack.runner_profile = "large"' \
  "$CONFIG" > "$profile_config"
profile_output="$TEST_DIR/profiles.out"
GITHUB_EVENT_NAME=workflow_dispatch \
GITHUB_REF_TYPE=branch \
GITHUB_REF_NAME=main \
GITHUB_OUTPUT="$profile_output" \
  "$SCRIPT_DIR/apko-plan.sh" "$profile_config"
profile_melange=$(output_value "$profile_output" melange_matrix_json)
assert_json "$profile_melange" '[.[].arch] | sort | join(",")' 'aarch64,x86_64'
assert_json "$profile_melange" 'all(.[]; .runner_profile == "large" and (has("runner") | not))' 'true'
assert_json "$(output_value "$profile_output" smoke_matrix_json)" '.' "$(jq . <<< "$branch_smoke")"

# Do not silently fall back when legacy labels or invalid profiles are supplied.
# Use a non-release tag to also exercise validation before planner early exits.
for change in \
  '.default_runners = {"x86_64": "audit-test-runner"}' \
  '.melange.stack.runners = {"x86_64": "audit-test-runner"}' \
  '.melange.stack.runner_profile = "audit-test-runner"' \
  '.melange.stack.runner_profile = ""' \
  '.melange.stack.runner_profile = "large "' \
  '.melange.stack.runner_profile = null' \
  '.melange.stack.runner_profile = false' \
  '.melange.stack.runner_profile = ["large"]'; do
  jq "$change" "$CONFIG" > "$TEST_DIR/rejected.json"
  : > "$TEST_DIR/rejected.out"
  if GITHUB_EVENT_NAME=push \
    GITHUB_REF_TYPE=tag \
    GITHUB_REF_NAME=not-a-release \
    GITHUB_OUTPUT="$TEST_DIR/rejected.out" \
      "$SCRIPT_DIR/apko-plan.sh" "$TEST_DIR/rejected.json" > "$TEST_DIR/rejected.log" 2>&1; then
    echo "planner accepted invalid runner configuration: $change" >&2
    exit 1
  fi
  if [[ -s "$TEST_DIR/rejected.out" ]]; then
    echo "planner emitted outputs for invalid runner configuration: $change" >&2
    exit 1
  fi
done

echo "apko-plan tests passed"
