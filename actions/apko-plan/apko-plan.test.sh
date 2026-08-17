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
  "default_runners": {"x86_64": "ubuntu-latest"},
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

echo "apko-plan tests passed"
