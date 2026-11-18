#!/usr/bin/env bash
# Tests for plan-images.sh. Requires bash 4.3+, jq, and git.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLAN="$SCRIPT_DIR/plan-images.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

SHA=0123456789abcdef0123456789abcdef01234567
DEFAULT_ENV=(
  GITHUB_EVENT_NAME=workflow_dispatch
  GITHUB_REF=refs/heads/main
  GITHUB_REF_NAME=main
  GITHUB_REF_TYPE=branch
  GITHUB_SHA="$SHA"
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# run_plan <name> <catalog> [env assignments...]
# Runs the planner in $TEST_DIR/<name>/ and sets OUT to its GITHUB_OUTPUT file.
run_plan() {
  local name="$1" cfg="$2"
  shift 2
  OUT="$TEST_DIR/$name.out"
  : > "$OUT"
  if ! env -i PATH="$PATH" HOME="${HOME:-/tmp}" GITHUB_OUTPUT="$OUT" "${DEFAULT_ENV[@]}" "$@" \
      bash "$PLAN" "$cfg" > "$TEST_DIR/$name.log" 2>&1; then
    cat "$TEST_DIR/$name.log" >&2
    fail "planner failed for $name"
  fi
}

out_value() {
  sed -n "s/^$2=//p" "$1"
}

# assert_json <json> <jq filter> <expected>
assert_json() {
  local json="$1" filter="$2" expected="$3" actual
  actual=$(jq -r "$filter" <<< "$json")
  if [[ "$actual" != "$expected" ]]; then
    fail "jq '$filter': expected '$expected', got '$actual'"
  fi
}

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    fail "$3: expected '$2', got '$1'"
  fi
}

# Catalog fixtures

write_v2_catalog() {
  cat > "$1" <<'JSON'
{
  "version": 2,
  "registry": "registry.example.invalid/images",
  "shared_paths": ["go.mod"],
  "release": {
    "tag_regex": "^([^/]+)/(v.+)$",
    "service_match": 1,
    "version_match": 2,
    "publish_tag": "${version}",
    "source_ref": "${ref_name}"
  },
  "packages": {
    "stack": {
      "config": "melange/stack.yaml",
      "archs": ["x86_64"]
    }
  },
  "images": {
    "widget": {
      "builders": {"docker": {"context": ".", "dockerfile": "Dockerfile"}},
      "paths": ["widget/**"],
      "smoke": {"commands": ["widget --version"], "verify_version": true}
    },
    "gadget": {
      "builders": {
        "apko": {
          "needs_packages": ["stack"],
          "configs": [
            {"config": "apko/gadget.yaml", "tag_suffix": ""},
            {"config": "apko/gadget-dev.yaml", "tag_suffix": "-dev"}
          ]
        }
      },
      "paths": ["gadget/**"],
      "smoke": {"commands": ["gadget --version"], "verify_version": true}
    }
  }
}
JSON
}

write_dual_catalog() {
  cat > "$1" <<'JSON'
{
  "version": 2,
  "registry": "registry.example.invalid/images",
  "tag_prefix": "",
  "packages": {
    "stack": {"config": "melange/stack.yaml", "archs": ["x86_64", "aarch64"]}
  },
  "images": {
    "both": {
      "builders": {
        "docker": {"dockerfile": "Dockerfile"},
        "apko": {"needs_packages": ["stack"]}
      },
      "primary": "docker",
      "paths": ["both/**"],
      "smoke": {"commands": ["/bin/sh -c true"]}
    }
  }
}
JSON
}

# Legacy v1 images.json (docker) and images.apko.json (apko) fixtures.
write_legacy_docker() {
  cat > "$1" <<'JSON'
{
  "registry": "registry.example.invalid/images",
  "shared_paths": ["go.mod"],
  "images": {
    "dockonly": {
      "context": ".",
      "dockerfile": "Dockerfile",
      "target": "app",
      "build_args": "ENVIRONMENT=staging",
      "paths": ["dockonly/**"]
    }
  }
}
JSON
}

write_legacy_apko() {
  cat > "$1" <<'JSON'
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
}

empty_legacy_docker() {
  echo '{"registry": "registry.example.invalid/images", "images": {}}' > "$1"
}

# Matrix helpers
matrix() { out_value "$OUT" "$1"; }

# --- v2 release tag -----------------------------------------------------------

v2="$TEST_DIR/v2.json"
write_v2_catalog "$v2"

run_plan release "$v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/widget/v1.2.3 \
  GITHUB_REF_NAME=widget/v1.2.3 GITHUB_REF_TYPE=tag TRUSTED=true
assert_eq "$(out_value "$OUT" is_release)" "true" "release is_release"
assert_eq "$(out_value "$OUT" trusted)" "true" "release trusted"
release_build=$(matrix build_matrix)
assert_json "$release_build" 'length' '0'
release_pub=$(matrix publish_matrix)
assert_json "$release_pub" 'length' '2'
assert_json "$release_pub" '[.[].image] | unique | join(",")' 'widget'
assert_json "$release_pub" '[.[].expected_version] | unique | join(",")' 'v1.2.3'
assert_json "$release_pub" '[.[].ref_tag] | unique | join(",")' 'v1.2.3'
assert_json "$(matrix smoke_arm64_matrix)" '.[0].expected_version' 'v1.2.3'
assert_json "$(matrix packages_matrix)" 'length' '0'
assert_eq "$(matrix selected_images)" "widget" "release selects only the tagged image"

# Release tag for an apko image: default variant verifies the version, dev variant does not.
run_plan release_gadget "$v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/gadget/v3.0.0 \
  GITHUB_REF_NAME=gadget/v3.0.0 GITHUB_REF_TYPE=tag TRUSTED=true
gadget_pub=$(matrix publish_matrix)
assert_json "$gadget_pub" 'length' '2'
assert_json "$gadget_pub" '[.[] | select(.suffix == "")][0].expected_version' 'v3.0.0'
assert_json "$gadget_pub" '[.[] | select(.suffix == "-dev")][0].expected_version' ''
assert_json "$gadget_pub" '[.[] | select(.suffix == "-dev")][0].smoke_commands' '[]'
assert_json "$gadget_pub" '[.[] | select(.suffix == "")][0].sha_tag' "$SHA"
assert_json "$gadget_pub" '[.[] | select(.suffix == "-dev")][0].sha_tag' "$SHA-dev"
assert_json "$(matrix packages_matrix)" 'length' '1'
assert_json "$(matrix packages_matrix)" '.[0].build_version' 'v3.0.0'

# Unknown tag: empty plan, exit 0, still a release.
run_plan invalid_tag "$v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/not-a-release \
  GITHUB_REF_NAME=not-a-release GITHUB_REF_TYPE=tag TRUSTED=true
assert_eq "$(out_value "$OUT" is_release)" "true" "invalid tag is_release"
for key in packages_matrix build_matrix publish_matrix manifest_matrix smoke_arm64_matrix; do
  assert_json "$(matrix $key)" 'length' '0'
done
assert_eq "$(out_value "$OUT" has_publish)" "false" "invalid tag has_publish"

# Tag for an image missing from the catalog: empty plan.
run_plan missing_image "$v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/nope/v1.0.0 \
  GITHUB_REF_NAME=nope/v1.0.0 GITHUB_REF_TYPE=tag TRUSTED=true
assert_json "$(matrix publish_matrix)" 'length' '0'

# --- v2 branch dispatch (full plan) -------------------------------------------

run_plan dispatch "$v2" TRUSTED=true
assert_eq "$(out_value "$OUT" is_release)" "false" "dispatch is_release"
assert_eq "$(out_value "$OUT" selected_images)" "gadget,widget" "dispatch full image set"
assert_json "$(matrix packages_matrix)" '.[0].build_version' ''
assert_json "$(matrix packages_matrix)" '.[0].runner' 'ubuntu-24.04'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .expected_version] | unique | join(",")' ''
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker" and .arch == "amd64") | .runner] | join(",")' 'ubuntu-24.04'
assert_json "$(matrix smoke_arm64_matrix)" '[.[] | select(.builder == "docker") | .runner] | join(",")' 'ubuntu-24.04-arm'
assert_json "$(matrix smoke_arm64_matrix)" '[.[] | select(.builder == "docker") | .final_artifact] | join(",")' 'final-widget-docker'

# --- Untrusted plan ------------------------------------------------------------

run_plan untrusted "$v2" GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge \
  GITHUB_REF_NAME=1/merge GITHUB_REF_TYPE=branch TRUSTED=false
assert_eq "$(out_value "$OUT" trusted)" "false" "untrusted trusted flag"
for key in publish_matrix manifest_matrix smoke_arm64_matrix; do
  assert_json "$(matrix $key)" 'length' '0'
done
assert_json "$(matrix packages_matrix)" '[.[].arch] | unique | join(",")' 'x86_64'
assert_json "$(matrix build_matrix)" '[.[].arch] | unique | join(",")' 'amd64'
assert_json "$(matrix build_matrix)" '[.[] | select(.builder == "apko") | .local_ref] | sort | join(",")' 'local/gadget-apko-dev:smoke,local/gadget-apko:smoke'
assert_json "$(matrix build_matrix)" 'length' '3'

# Untrusted plan keeps an arm64-only image out of the build matrix.
arm_only="$TEST_DIR/arm-only.json"
jq '.images.widget.archs = ["arm64"]' "$v2" > "$arm_only"
run_plan untrusted_arm "$arm_only" GITHUB_EVENT_NAME=pull_request TRUSTED=false
assert_json "$(matrix build_matrix)" '[.[] | select(.image == "widget")] | length' '0'

# --- Runner profiles ------------------------------------------------------------

large="$TEST_DIR/large.json"
jq '.packages.stack.runner_profile = "large" | .packages.stack.archs = ["x86_64", "aarch64"]' "$v2" > "$large"
run_plan large "$large" TRUSTED=true
assert_json "$(matrix packages_matrix)" 'sort_by(.arch) | map(.runner) | join(",")' 'oplabs-ubuntu-arm,oplabs-ubuntu-x86'

for change in \
  '.packages.stack.runner_profile = null' \
  '.packages.stack.runner_profile = ""' \
  '.packages.stack.runner_profile = "large "' \
  '.packages.stack.runner_profile = false' \
  '.packages.stack.runner_profile = ["large"]' \
  '.packages.stack.runner_profile = "audit-test-runner"'; do
  jq "$change" "$v2" > "$TEST_DIR/rejected.json"
  : > "$TEST_DIR/rejected.out"
  if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/rejected.out" GITHUB_EVENT_NAME=workflow_dispatch \
      GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
      bash "$PLAN" "$TEST_DIR/rejected.json" > "$TEST_DIR/rejected.log" 2>&1; then
    fail "planner accepted invalid runner configuration: $change"
  fi
  if [[ -s "$TEST_DIR/rejected.out" ]]; then
    fail "planner emitted outputs for invalid runner configuration: $change"
  fi
done

# --- Docker-only image, dual builder, tag prefixes ---------------------------------

dual="$TEST_DIR/dual.json"
write_dual_catalog "$dual"
run_plan dual "$dual" TRUSTED=true
assert_json "$(matrix publish_matrix)" '[.[] | select(.kind == "apko") | .sha_tag] | join(",")' "apko-$SHA"
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .sha_tag] | unique | join(",")' "$SHA"
assert_json "$(matrix manifest_matrix)" '.[0].sha_tag' "$SHA"
assert_json "$(matrix manifest_matrix)" 'length' '1'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .arch] | join(",")' 'amd64,arm64'
assert_json "$(matrix publish_matrix)" '[.[] | select(.arch == "arm64") | .runner] | join(",")' 'ubuntu-24.04-arm'
assert_json "$(matrix publish_matrix)" '[.[] | select(.arch == "amd64" and .builder == "docker") | .smoke_local] | join(",")' 'true'
assert_json "$(matrix publish_matrix)" '[.[] | select(.arch == "arm64") | .smoke_local] | join(",")' 'false'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "apko") | .archs] | join(",")' 'amd64,arm64'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "apko") | .needs_packages] | join(",")' 'stack'
assert_json "$(matrix smoke_arm64_matrix)" 'length' '2'

# Secondary builder in a dual image gets the builder-prefixed tags.
dual_apko_first="$TEST_DIR/dual-apko-first.json"
jq '.images.both.primary = "apko" | .tag_prefix = "x-"' "$dual" > "$dual_apko_first"
run_plan dual_apko_first "$dual_apko_first" TRUSTED=true
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "apko") | .sha_tag] | join(",")' "x-$SHA"
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .sha_tag] | unique | join(",")' "x-docker-$SHA"

# A dual image without a primary is rejected.
no_primary="$TEST_DIR/no-primary.json"
jq 'del(.images.both.primary)' "$dual" > "$no_primary"
if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/np.out" GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
    bash "$PLAN" "$no_primary" > "$TEST_DIR/np.log" 2>&1; then
  fail "dual image without primary was accepted"
fi
grep -q 'primary is required' "$TEST_DIR/np.log" || fail "missing primary error message"

# --- Legacy two-file merge -------------------------------------------------------

legacy_dir="$TEST_DIR/legacy"
mkdir -p "$legacy_dir/.github"
pushd "$legacy_dir" >/dev/null
write_legacy_docker .github/images.json
write_legacy_apko .github/images.apko.json
run_plan legacy_merge .github/images.json TRUSTED=true
popd >/dev/null
assert_eq "$(out_value "$OUT" selected_images)" "dockonly,gadget,widget" "legacy merged image set"
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .image] | unique | join(",")' 'dockonly'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .build_args] | unique | join(",")' 'ENVIRONMENT=staging'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .target] | unique | join(",")' 'app'
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "gadget" and .suffix == "-dev") | .sha_tag] | join(",")' "$SHA-dev"
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "gadget" and .suffix == "") | .smoke_commands] | join(",")' '["gadget --version"]'
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "gadget" and .suffix == "-dev") | .smoke_commands] | join(",")' '[]'
assert_json "$(matrix packages_matrix)" '[.[].package] | unique | join(",")' 'stack'
assert_json "$(matrix packages_matrix)" '[.[].arch] | join(",")' 'x86_64'

# The legacy apko-only fixture from the earlier planner, against an empty docker catalog.
legacy_apko_only="$TEST_DIR/legacy-apko-only"
mkdir -p "$legacy_apko_only/.github"
pushd "$legacy_apko_only" >/dev/null
empty_legacy_docker .github/images.json
write_legacy_apko .github/images.apko.json
run_plan legacy_apko .github/images.json GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/gadget/v3.0.0 \
  GITHUB_REF_NAME=gadget/v3.0.0 GITHUB_REF_TYPE=tag TRUSTED=true
popd >/dev/null
legacy_pub=$(matrix publish_matrix)
assert_json "$legacy_pub" 'length' '2'
assert_json "$legacy_pub" '[.[].image] | unique | join(",")' 'gadget'
assert_json "$legacy_pub" '[.[] | select(.suffix == "")][0].expected_version' 'v3.0.0'
assert_json "$legacy_pub" '[.[] | select(.suffix == "-dev")][0].smoke_commands' '[]'
assert_json "$(matrix packages_matrix)" 'length' '1'
# The legacy fixture builds amd64 only, so no arm64 smoke leg is planned.
assert_json "$(matrix smoke_arm64_matrix)" 'length' '0'

# Legacy docker catalogs with a same-name apko entry become dual-builder images.
legacy_dual_dir="$TEST_DIR/legacy-dual"
mkdir -p "$legacy_dual_dir/.github"
pushd "$legacy_dual_dir" >/dev/null
cat > .github/images.json <<'JSON'
{"registry": "registry.example.invalid/images", "images": {"shared": {"context": ".", "dockerfile": "Dockerfile", "paths": ["shared/**"]}}}
JSON
cat > .github/images.apko.json <<'JSON'
{"melange": {}, "images": {"shared": {"smoke_test": "shared --version", "paths": ["shared/**"]}}}
JSON
run_plan legacy_dual .github/images.json TRUSTED=true
popd >/dev/null
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "apko") | .sha_tag] | join(",")' "apko-$SHA"
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .sha_tag] | unique | join(",")' "$SHA"

# Legacy formats this planner does not support fail loudly.
unsupported_dir="$TEST_DIR/unsupported"
mkdir -p "$unsupported_dir/.github"
pushd "$unsupported_dir" >/dev/null
echo '{"images": {}, "apko_images": {"x": {}}}' > .github/images.json
if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/unsupported.out" GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
    bash "$PLAN" .github/images.json > "$TEST_DIR/unsupported.log" 2>&1; then
  fail "apko_images catalog was accepted"
fi
echo '{"images": {"ko-img": {"mode": "ko", "paths": ["x/**"]}}}' > .github/images.json
if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/unsupported2.out" GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
    bash "$PLAN" .github/images.json > "$TEST_DIR/unsupported2.log" 2>&1; then
  fail "ko mode catalog was accepted"
fi
popd >/dev/null

# --- Registry requirement -----------------------------------------------------------

no_registry="$TEST_DIR/no-registry.json"
jq 'del(.registry)' "$v2" > "$no_registry"
if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/nr.out" GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
    bash "$PLAN" "$no_registry" > "$TEST_DIR/nr.log" 2>&1; then
  fail "trusted plan without registry was accepted"
fi

# --- Pre-build hook -----------------------------------------------------------------

hook_dir="$TEST_DIR/hook"
mkdir -p "$hook_dir/scripts"
cat > "$hook_dir/scripts/pre-build.sh" <<'SH'
#!/usr/bin/env bash
echo "BUILD_LABEL=ci-42"
SH
hook_cat="$hook_dir/catalog.json"
jq '.hooks = {"pre_build": "scripts/pre-build.sh"} | .packages.stack.build_env = "EXTRA=1"' "$dual" > "$hook_cat"
pushd "$hook_dir" >/dev/null
run_plan hook "$hook_cat" TRUSTED=true
popd >/dev/null
assert_json "$(matrix packages_matrix)" '.[0].build_env' $'BUILD_LABEL=ci-42\nEXTRA=1'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .build_args] | unique | join(",")' 'BUILD_LABEL=ci-42'

bad_hook_dir="$TEST_DIR/bad-hook"
mkdir -p "$bad_hook_dir/scripts"
printf '#!/usr/bin/env bash\necho "not a pair"\n' > "$bad_hook_dir/scripts/bad.sh"
jq '.hooks = {"pre_build": "scripts/bad.sh"}' "$dual" > "$bad_hook_dir/catalog.json"
if (cd "$bad_hook_dir" && env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/bh.out" GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
    bash "$PLAN" catalog.json > "$TEST_DIR/bh.log" 2>&1); then
  fail "non KEY=VALUE hook output was accepted"
fi

# --- Change detection on pull requests ------------------------------------------------

repo="$TEST_DIR/repo"
mkdir -p "$repo/.github" "$repo/widget" "$repo/gadget" "$repo/melange" "$repo/apko"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
cp "$v2" "$repo/.github/images.json"
echo base > "$repo/widget/a.txt"
echo base > "$repo/gadget/a.txt"
echo base > "$repo/melange/stack.yaml"
echo base > "$repo/go.mod"
git -C "$repo" add -A
git -C "$repo" commit -q -m base
base_sha=$(git -C "$repo" rev-parse HEAD)

pr_change() {
  local name="$1" file="$2"
  mkdir -p "$(dirname "$repo/$file")"
  printf '\n' >> "$repo/$file"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$name"
  local head_sha
  head_sha=$(git -C "$repo" rev-parse HEAD)
  printf '{"pull_request":{"base":{"sha":"%s"},"head":{"sha":"%s"}}}' "$base_sha" "$head_sha" > "$TEST_DIR/event-$name.json"
  pushd "$repo" >/dev/null
  run_plan "pr-$name" .github/images.json GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge \
    GITHUB_REF_NAME=1/merge GITHUB_REF_TYPE=branch GITHUB_SHA="$head_sha" \
    GITHUB_EVENT_PATH="$TEST_DIR/event-$name.json" TRUSTED=false
  popd >/dev/null
  git -C "$repo" reset -q --hard "$base_sha"
}

pr_change widget-only widget/b.txt
assert_eq "$(out_value "$OUT" selected_images)" "widget" "PR change to widget selects widget only"
assert_json "$(matrix packages_matrix)" 'length' '0'

pr_change gadget-only gadget/b.txt
assert_eq "$(out_value "$OUT" selected_images)" "gadget" "PR change to gadget selects gadget"
assert_json "$(matrix packages_matrix)" '[.[].package] | join(",")' 'stack'

pr_change shared go.mod
assert_eq "$(out_value "$OUT" selected_images)" "gadget,widget" "shared path selects every image"

pr_change package-config melange/stack.yaml
assert_eq "$(out_value "$OUT" selected_images)" "gadget" "package config change selects dependent images"
assert_json "$(matrix packages_matrix)" '[.[].package] | join(",")' 'stack'

pr_change catalog .github/images.json
assert_eq "$(out_value "$OUT" selected_images)" "gadget,widget" "catalog change plans the full catalog"

pr_change unrelated docs/readme.md
assert_eq "$(out_value "$OUT" selected_images)" "" "unrelated change selects nothing"
assert_json "$(matrix build_matrix)" 'length' '0'

echo "plan-images tests passed"
