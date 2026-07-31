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
      "smoke_test": "widget --version"
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

echo "apko-plan tests passed"
