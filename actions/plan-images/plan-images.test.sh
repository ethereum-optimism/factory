#!/usr/bin/env bash
# Tests for plan-images.sh. Requires bash 4.3+, jq, and git.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLAN="$SCRIPT_DIR/plan-images.sh"
TEST_DIR=$(mktemp -d)

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
  "registry": "registry.example.invalid/images",
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
assert_json "$(matrix smoke_matrix)" '[.[].expected_version] | unique | join(",")' 'v1.2.3'
assert_json "$release_pub" '[.[].ref_tag] | unique | join(",")' 'v1.2.3'
assert_json "$(matrix smoke_matrix)" '.[0].expected_version' 'v1.2.3'
assert_json "$(matrix packages_matrix)" 'length' '0'
assert_eq "$(matrix selected_images)" "widget" "release selects only the tagged image"

# Release tag for an apko image: default variant verifies the version, dev variant does not.
run_plan release_gadget "$v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/gadget/v3.0.0 \
  GITHUB_REF_NAME=gadget/v3.0.0 GITHUB_REF_TYPE=tag TRUSTED=true
gadget_pub=$(matrix publish_matrix)
assert_json "$gadget_pub" 'length' '2'
assert_json "$(matrix smoke_matrix)" '[.[].expected_version] | unique | join(",")' 'v3.0.0'
assert_json "$(matrix smoke_matrix)" '[.[].id] | sort | join(",")' 'gadget-apko-amd64,gadget-apko-arm64'
assert_json "$gadget_pub" '[.[] | select(.suffix == "")][0].sha_tag' "$SHA"
assert_json "$gadget_pub" '[.[] | select(.suffix == "-dev")][0].sha_tag' "$SHA-dev"
assert_json "$(matrix packages_matrix)" 'length' '1'
assert_json "$(matrix packages_matrix)" '.[0].build_version' 'v3.0.0'

# Unknown tag: empty plan, exit 0, still a release.
run_plan invalid_tag "$v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/not-a-release \
  GITHUB_REF_NAME=not-a-release GITHUB_REF_TYPE=tag TRUSTED=true
assert_eq "$(out_value "$OUT" is_release)" "true" "invalid tag is_release"
for key in packages_matrix build_matrix publish_matrix manifest_matrix smoke_matrix; do
  assert_json "$(matrix $key)" 'length' '0'
done
assert_eq "$(out_value "$OUT" has_publish)" "false" "invalid tag has_publish"

# Tag for an image missing from the catalog: empty plan.
run_plan missing_image "$v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/nope/v1.0.0 \
  GITHUB_REF_NAME=nope/v1.0.0 GITHUB_REF_TYPE=tag TRUSTED=true
assert_json "$(matrix publish_matrix)" 'length' '0'

# --- Release version as a docker build argument ---------------------------------------

build_arg_v2="$TEST_DIR/build-arg-v2.json"
jq '.images.widget.builders.docker.build_args = {"VERSION": "v0.0.0", "FOO": "bar"}' "$v2" > "$build_arg_v2"
widget_docker_args='[.[] | select(.image == "widget" and .builder == "docker")][0].build_args | split("\n") | sort | join(",")'

# Release tag, trusted: the version replaces the catalog VERSION and keeps other arguments.
run_plan build_arg_release "$build_arg_v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/widget/v1.2.3 \
  GITHUB_REF_NAME=widget/v1.2.3 GITHUB_REF_TYPE=tag TRUSTED=true
assert_json "$(matrix publish_matrix)" "$widget_docker_args" 'FOO=bar,VERSION=v1.2.3'

# Release tag, untrusted: the build leg gets the version too.
run_plan build_arg_release_untrusted "$build_arg_v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/widget/v1.2.3 \
  GITHUB_REF_NAME=widget/v1.2.3 GITHUB_REF_TYPE=tag TRUSTED=false
assert_json "$(matrix build_matrix)" "$widget_docker_args" 'FOO=bar,VERSION=v1.2.3'

# Release tag without a catalog build_args entry: the version is the only argument.
run_plan build_arg_release_bare "$v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/widget/v1.2.3 \
  GITHUB_REF_NAME=widget/v1.2.3 GITHUB_REF_TYPE=tag TRUSTED=true
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "widget" and .builder == "docker")][0].build_args' 'VERSION=v1.2.3'

# Main push: no version is injected and the catalog VERSION passes through.
run_plan build_arg_main "$build_arg_v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true
assert_json "$(matrix publish_matrix)" "$widget_docker_args" 'FOO=bar,VERSION=v0.0.0'

# Bake mode never reads build_args, so a release tag adds nothing to them.
build_arg_bake="$TEST_DIR/build-arg-bake.json"
jq '.images.widget.builders.docker.mode = "bake" | .images.widget.builders.docker.build_args = {"FOO": "bar"}' "$v2" > "$build_arg_bake"
run_plan build_arg_bake_release "$build_arg_bake" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/widget/v1.2.3 \
  GITHUB_REF_NAME=widget/v1.2.3 GITHUB_REF_TYPE=tag TRUSTED=true
assert_json "$(matrix publish_matrix)" "$widget_docker_args" 'FOO=bar'

# --- v2 branch dispatch (full plan) -------------------------------------------

run_plan dispatch "$v2" TRUSTED=true
assert_eq "$(out_value "$OUT" is_release)" "false" "dispatch is_release"
assert_eq "$(out_value "$OUT" selected_images)" "gadget,widget" "dispatch full image set"
assert_json "$(matrix packages_matrix)" '.[0].build_version' ''
assert_json "$(matrix packages_matrix)" '.[0].runner' 'ubuntu-24.04'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker" and .arch == "amd64") | .runner] | join(",")' 'ubuntu-24.04'
assert_json "$(matrix smoke_matrix)" '[.[] | select(.arch == "arm64") | .runner] | unique | join(",")' 'ubuntu-24.04-arm'
assert_json "$(matrix smoke_matrix)" '[.[] | select(.arch == "amd64") | .runner] | unique | join(",")' 'ubuntu-24.04'
assert_json "$(matrix smoke_matrix)" '[.[] | select(.builder == "docker") | .final_artifact] | unique | join(",")' 'final-widget-docker'

# --- Untrusted plan ------------------------------------------------------------

run_plan untrusted "$v2" GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge \
  GITHUB_REF_NAME=1/merge GITHUB_REF_TYPE=branch TRUSTED=false
assert_eq "$(out_value "$OUT" trusted)" "false" "untrusted trusted flag"
for key in publish_matrix manifest_matrix smoke_matrix; do
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
assert_json "$(matrix publish_matrix)" '[.[] | select(.arch == "arm64") | .runner] | unique | join(",")' 'ubuntu-24.04-arm'
assert_json "$(matrix publish_matrix)" '[.[] | has("smoke_local") or has("smoke_commands")] | any' 'false'
assert_eq "$(out_value "$OUT" has_smoke)" "true" "dual has_smoke"
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "apko") | .archs] | join(",")' 'amd64,arm64'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "apko") | .needs_packages] | join(",")' 'stack'
assert_json "$(matrix smoke_matrix)" 'length' '4'
assert_json "$(matrix smoke_matrix)" '[.[] | select(.builder == "apko") | .id] | sort | join(",")' 'both-apko-amd64,both-apko-arm64'

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
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "gadget" and .suffix == "-dev") | .sha_tag] | join(",")' "apko-$SHA-dev"
assert_json "$(matrix smoke_matrix)" '[.[] | select(.image == "gadget") | .smoke_commands] | unique | join(",")' '["gadget --version"]'
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
assert_json "$(matrix smoke_matrix)" '[.[].id] | sort | join(",")' 'gadget-apko-amd64'
assert_json "$(matrix packages_matrix)" 'length' '1'
# The legacy fixture builds amd64 only, so no arm64 smoke leg is planned.
assert_json "$(matrix smoke_matrix)" 'length' '1'
assert_json "$(matrix smoke_matrix)" '.[0].arch' 'amd64'

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
echo '{"registry": "registry.example.invalid/images", "images": {"odd-img": {"mode": "pulumi", "paths": ["x/**"]}}}' > .github/images.json
if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/unsupported2.out" GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
    bash "$PLAN" .github/images.json > "$TEST_DIR/unsupported2.log" 2>&1; then
  fail "unknown legacy mode was accepted"
fi
grep -q 'mode pulumi is not supported' "$TEST_DIR/unsupported2.log" || fail "missing unknown legacy mode error"
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

# --- Release ref tag matches the legacy sanitized ref name ----------------------

default_release="$TEST_DIR/default-release.json"
jq 'del(.release.publish_tag)' "$v2" > "$default_release"
run_plan default_release "$default_release" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/widget/v1.2.3 \
  GITHUB_REF_NAME=widget/v1.2.3 GITHUB_REF_TYPE=tag TRUSTED=true
legacy_ref_tag=$(printf '%s' "widget/v1.2.3" | sed 's/[^a-zA-Z0-9.]/-/g')
assert_eq "$legacy_ref_tag" "widget-v1.2.3" "legacy sanitize formula"
assert_json "$(matrix publish_matrix)" '[.[].ref_tag] | unique | join(",")' "$legacy_ref_tag"

# --- Builder tag_prefix overrides ----------------------------------------------

apko_only="$TEST_DIR/apko-only.json"
jq '.images = {"gadget": {"builders": {"apko": {"config": "apko/gadget.yaml", "tag_prefix": "apko-", "needs_packages": ["stack"]}}, "paths": ["gadget/**"]}}' "$v2" > "$apko_only"
run_plan apko_only_prefix "$apko_only" TRUSTED=true
assert_json "$(matrix publish_matrix)" '.[0].sha_tag' "apko-$SHA"
assert_json "$(matrix publish_matrix)" '.[0].ref_tag' "apko-main"

bad_builder_prefix="$TEST_DIR/bad-builder-prefix.json"
jq '.images.widget.builders.docker.tag_prefix = "bad_prefix!"' "$v2" > "$bad_builder_prefix"
if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/bbp.out" GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
    bash "$PLAN" "$bad_builder_prefix" > "$TEST_DIR/bbp.log" 2>&1; then
  fail "invalid builder tag_prefix was accepted"
fi

# --- Legacy apko tag prefix depends on the docker catalog -----------------------

apko_only_dir="$TEST_DIR/legacy-apko-without-docker"
mkdir -p "$apko_only_dir/.github"
pushd "$apko_only_dir" >/dev/null
write_legacy_apko .github/images.apko.json
run_plan legacy_apko_no_docker .github/images.json TRUSTED=true
popd >/dev/null
assert_json "$(matrix publish_matrix)" '[.[] | select(.suffix == "")][0].sha_tag' "$SHA"

# --- Name validation ----------------------------------------------------------------

bad_package="$TEST_DIR/bad-package.json"
jq '.packages.Bad_Name = {"config": "melange/x.yaml"}' "$dual" > "$bad_package"
if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/bp.out" GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
    bash "$PLAN" "$bad_package" > "$TEST_DIR/bp.log" 2>&1; then
  fail "invalid package name was accepted"
fi

# --- Untrusted runners and notices ----------------------------------------------------

run_plan untrusted_large "$large" TRUSTED=false
assert_json "$(matrix packages_matrix)" '[.[].runner] | unique | join(",")' 'ubuntu-24.04'
grep -q '^::notice::Image widget has no amd64 architecture' "$TEST_DIR/untrusted_arm.log" \
  || fail "missing untrusted skip notice"
grep -q "^::notice::Release tag 'not-a-release' does not match" "$TEST_DIR/invalid_tag.log" \
  || fail "missing unknown tag notice"

# --- Per-builder archs -----------------------------------------------------------------

# Docker publishes amd64 only while apko publishes amd64 and arm64.
dual_archs="$TEST_DIR/dual-archs.json"
jq '.images.both.builders.docker.archs = ["amd64"]' "$dual" > "$dual_archs"
run_plan dual_archs "$dual_archs" TRUSTED=true
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker")] | length' '1'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .arch] | join(",")' 'amd64'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .sha_tag] | unique | join(",")' "$SHA"
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "apko") | .archs] | join(",")' 'amd64,arm64'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "apko") | .sha_tag] | join(",")' "apko-$SHA"
assert_json "$(matrix manifest_matrix)" 'length' '1'
assert_json "$(matrix manifest_matrix)" '.[0].sha_tag' "$SHA"
assert_json "$(matrix manifest_matrix)" '.[0].pushed_pattern' 'pushed-both-docker-*'
assert_json "$(matrix smoke_matrix)" '[.[] | select(.builder == "docker") | .id] | join(",")' 'both-docker-amd64'
assert_json "$(matrix smoke_matrix)" '[.[] | select(.builder == "apko") | .id] | sort | join(",")' 'both-apko-amd64,both-apko-arm64'
assert_json "$(matrix smoke_matrix)" 'length' '3'

# A single-arch docker builder keeps the same manifest and attestation path as an image-level single arch.
single_image="$TEST_DIR/single-image.json"
jq '.images.both.archs = ["amd64"] | del(.images.both.builders.docker.archs)' "$dual" > "$single_image"
run_plan single_image "$single_image" TRUSTED=true
assert_json "$(matrix manifest_matrix)" '.[0].id' 'both-docker'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .arch] | join(",")' 'amd64'
assert_json "$(matrix smoke_matrix)" '[.[] | select(.builder == "docker") | .id] | join(",")' 'both-docker-amd64'

# Builder-level archs override the image-level archs; the other builder inherits them.
override="$TEST_DIR/override.json"
jq '.images.both.archs = ["arm64"] | .images.both.builders.apko.archs = ["amd64"]' "$dual" > "$override"
run_plan override "$override" TRUSTED=true
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .arch] | join(",")' 'arm64'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "apko") | .archs] | join(",")' 'amd64'
assert_json "$(matrix smoke_matrix)" '[.[] | select(.builder == "apko") | .arch] | join(",")' 'amd64'
assert_json "$(matrix smoke_matrix)" '[.[] | select(.builder == "docker") | .arch] | join(",")' 'arm64'

# Untrusted runs build amd64 per builder: the docker builder is skipped when its archs exclude amd64.
run_plan untrusted_dual "$dual_archs" GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge \
  GITHUB_REF_NAME=1/merge GITHUB_REF_TYPE=branch TRUSTED=false
assert_json "$(matrix build_matrix)" '[.[] | select(.builder == "docker") | .arch] | join(",")' 'amd64'
assert_json "$(matrix build_matrix)" '[.[] | select(.builder == "apko") | .arch] | join(",")' 'amd64'
for key in publish_matrix manifest_matrix smoke_matrix; do
  assert_json "$(matrix $key)" 'length' '0'
done

arm_docker="$TEST_DIR/arm-docker.json"
jq '.images.both.builders.docker.archs = ["arm64"]' "$dual" > "$arm_docker"
run_plan untrusted_arm_docker "$arm_docker" GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge \
  GITHUB_REF_NAME=1/merge GITHUB_REF_TYPE=branch TRUSTED=false
assert_json "$(matrix build_matrix)" '[.[] | select(.builder == "docker") | .id] | length' '0'
assert_json "$(matrix build_matrix)" '[.[] | select(.builder == "apko") | .arch] | join(",")' 'amd64'
grep -q '^::notice::Image both builder docker has no amd64 architecture; skipped on this untrusted run' \
  "$TEST_DIR/untrusted_arm_docker.log" || fail "missing untrusted builder skip notice"

# Invalid builder archs are rejected.
for change in '.images.both.builders.docker.archs = ["x86_64"]' '.images.both.builders.apko.archs = []'; do
  jq "$change" "$dual" > "$TEST_DIR/bad-builder-archs.json"
  : > "$TEST_DIR/bad-builder-archs.out"
  if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/bad-builder-archs.out" GITHUB_EVENT_NAME=workflow_dispatch \
      GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
      bash "$PLAN" "$TEST_DIR/bad-builder-archs.json" > "$TEST_DIR/bad-builder-archs.log" 2>&1; then
    fail "planner accepted invalid builder archs: $change"
  fi
  grep -q 'builders\..*\.archs must be a non-empty subset' "$TEST_DIR/bad-builder-archs.log" \
    || fail "missing builder archs error for: $change"
done

# --- Per-builder smoke ---------------------------------------------------------------

# Each builder smokes its own binary: the untrusted build legs and the trusted smoke legs carry the builder's commands.
dual_smoke="$TEST_DIR/dual-smoke.json"
jq '.images.both.builders.docker.smoke = {"commands": ["/bin/tool --version"]}
  | .images.both.builders.apko.smoke = {"commands": ["mytool --version"]}' "$dual" > "$dual_smoke"
run_plan dual_smoke "$dual_smoke" TRUSTED=true
assert_json "$(matrix smoke_matrix)" '[.[] | select(.builder == "docker") | .smoke_commands | fromjson | join(" ")] | unique | join(",")' '/bin/tool --version'
assert_json "$(matrix smoke_matrix)" '[.[] | select(.builder == "apko") | .smoke_commands | fromjson | join(" ")] | unique | join(",")' 'mytool --version'
assert_json "$(matrix smoke_matrix)" 'length' '4'
run_plan dual_smoke_untrusted "$dual_smoke" GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge \
  GITHUB_REF_NAME=1/merge GITHUB_REF_TYPE=branch TRUSTED=false
assert_json "$(matrix build_matrix)" '[.[] | select(.builder == "docker") | .smoke_commands | fromjson | join(" ")] | unique | join(",")' '/bin/tool --version'
assert_json "$(matrix build_matrix)" '[.[] | select(.builder == "apko") | .smoke_commands | fromjson | join(" ")] | unique | join(",")' 'mytool --version'
assert_json "$(matrix build_matrix)" '[.[] | select(.has_smoke == true) | .id] | sort | join(",")' 'both-apko,both-docker'

# Builder-level smoke replaces the image smoke entirely: image verify_version is not inherited.
verify_builder="$TEST_DIR/verify-builder.json"
jq --argjson r "$(jq '.release' "$v2")" '. + {release: $r}
  | .images.both.smoke.verify_version = true
  | .images.both.builders.docker.smoke = {"commands": ["/bin/tool --version"]}' "$dual" > "$verify_builder"
run_plan verify_builder "$verify_builder" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/both/v1.2.3 \
  GITHUB_REF_NAME=both/v1.2.3 GITHUB_REF_TYPE=tag TRUSTED=true
assert_json "$(matrix smoke_matrix)" '[.[] | select(.builder == "docker") | .expected_version] | unique | join(",")' ''
assert_json "$(matrix smoke_matrix)" '[.[] | select(.builder == "apko") | .expected_version] | unique | join(",")' 'v1.2.3'

# An empty builder smoke disables smoke for that builder only, in either form.
for empty in '{}' '{"commands": []}'; do
  no_apko_smoke="$TEST_DIR/no-apko-smoke.json"
  jq --argjson e "$empty" '.images.both.builders.apko.smoke = $e' "$dual" > "$no_apko_smoke"
  run_plan no_apko_smoke "$no_apko_smoke" TRUSTED=true
  assert_json "$(matrix smoke_matrix)" '[.[] | select(.builder == "apko")] | length' '0'
  assert_json "$(matrix smoke_matrix)" '[.[] | select(.builder == "docker") | .id] | sort | join(",")' 'both-docker-amd64,both-docker-arm64'
  assert_eq "$(out_value "$OUT" has_smoke)" "true" "docker still smokes with empty apko smoke"
  run_plan no_apko_smoke_untrusted "$no_apko_smoke" GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge \
    GITHUB_REF_NAME=1/merge GITHUB_REF_TYPE=branch TRUSTED=false
  assert_json "$(matrix build_matrix)" '[.[] | select(.builder == "apko") | .has_smoke] | unique | join(",")' 'false'
  assert_json "$(matrix build_matrix)" '[.[] | select(.builder == "docker") | .has_smoke] | unique | join(",")' 'true'
done

# Without a builder override, the image smoke still applies to both builders.
run_plan image_smoke "$dual" TRUSTED=true
assert_json "$(matrix smoke_matrix)" '[.[] | .smoke_commands | fromjson | join(" ")] | unique | join(",")' '/bin/sh -c true'
assert_json "$(matrix smoke_matrix)" 'length' '4'

# A builder smoke that is not a boolean verify_version is rejected.
bad_verify="$TEST_DIR/bad-verify.json"
jq '.images.both.builders.apko.smoke = {"verify_version": "yes"}' "$dual" > "$bad_verify"
if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/bad-verify.out" GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
    bash "$PLAN" "$bad_verify" > "$TEST_DIR/bad-verify.log" 2>&1; then
  fail "planner accepted a non-boolean builder smoke verify_version"
fi
grep -q 'builders\.apko\.smoke\.verify_version must be boolean' "$TEST_DIR/bad-verify.log" \
  || fail "missing builder smoke verify_version error"

# --- Hook runs without Actions file commands -----------------------------------------

hook_env_dir="$TEST_DIR/hook-env"
mkdir -p "$hook_env_dir/scripts"
cat > "$hook_env_dir/scripts/env-hook.sh" <<'SH'
#!/usr/bin/env bash
echo "HOOK_ENV_SEEN=${GITHUB_ENV:-unset}"
SH
jq '.hooks = {"pre_build": "scripts/env-hook.sh"}' "$dual" > "$hook_env_dir/catalog.json"
pushd "$hook_env_dir" >/dev/null
run_plan hook_env catalog.json TRUSTED=true GITHUB_ENV="$TEST_DIR/github-env-file"
popd >/dev/null
assert_json "$(matrix packages_matrix)" '.[0].build_env' 'HOOK_ENV_SEEN=unset'

# --- ko builder mode ----------------------------------------------------------------

ko_v2="$TEST_DIR/ko-v2.json"
cat > "$ko_v2" <<'JSON'
{
  "version": 2,
  "registry": "registry.example.invalid/images",
  "release": {
    "tag_regex": "^([^/]+)/(v.+)$",
    "service_match": 1,
    "version_match": 2,
    "publish_tag": "${version}",
    "source_ref": "${ref_name}"
  },
  "images": {
    "ko-app": {
      "builders": {
        "docker": {
          "mode": "ko",
          "context": "ko-app",
          "importpath": ".",
          "ko_config": "ko-app/.ko.yaml",
          "ldflags": ["-s", "-w"],
          "env": ["CGO_ENABLED=0"]
        }
      },
      "paths": ["ko-app/**"],
      "smoke": {"commands": ["/ko-app"], "verify_version": true}
    }
  }
}
JSON

# Untrusted: one amd64 build leg, no publish, manifest or smoke legs.
run_plan ko_untrusted "$ko_v2" GITHUB_EVENT_NAME=workflow_dispatch TRUSTED=false
assert_json "$(matrix build_matrix)" 'length' '1'
assert_json "$(matrix build_matrix)" '.[0] | [.builder, .mode, .arch, .local_ref, .context, .importpath, .ko_config] | join("|")' 'docker|ko|amd64|local/ko-app-docker:smoke|ko-app|.|ko-app/.ko.yaml'
assert_json "$(matrix build_matrix)" '.[0].ldflags | split("\n") | join(",")' '-s,-w'
assert_json "$(matrix build_matrix)" '.[0].env' 'CGO_ENABLED=0'
assert_json "$(matrix publish_matrix)" 'length' '0'
assert_json "$(matrix manifest_matrix)" 'length' '0'
assert_json "$(matrix smoke_matrix)" 'length' '0'

# Trusted: one multi-platform publish leg, no manifest leg, one smoke leg per arch.
run_plan ko_trusted "$ko_v2" GITHUB_EVENT_NAME=workflow_dispatch TRUSTED=true
assert_json "$(matrix build_matrix)" 'length' '0'
assert_json "$(matrix publish_matrix)" 'length' '1'
assert_json "$(matrix publish_matrix)" '.[0] | [.id, .kind, .archs, .runner, .sha_tag, .ref_tag, .registry] | join("|")' "ko-app-ko|ko|amd64,arm64|ubuntu-24.04|$SHA|main|registry.example.invalid/images"
assert_json "$(matrix publish_matrix)" '.[0].env' 'CGO_ENABLED=0'
assert_json "$(matrix publish_matrix)" '.[0].importpath' '.'
assert_json "$(matrix manifest_matrix)" 'length' '0'
assert_eq "$(out_value "$OUT" has_manifest)" "false" "ko has_manifest"
assert_json "$(matrix smoke_matrix)" '[.[].id] | sort | join(",")' 'ko-app-ko-amd64,ko-app-ko-arm64'
assert_json "$(matrix smoke_matrix)" '[.[].final_artifact] | unique | join(",")' 'final-ko-app-ko'
assert_json "$(matrix smoke_matrix)" '[.[] | select(.arch == "arm64") | .runner] | unique | join(",")' 'ubuntu-24.04-arm'
assert_json "$(matrix smoke_matrix)" '[.[].expected_version] | unique | join(",")' ''

# Release tag: the version reaches the ko publish tags and both smoke legs.
run_plan ko_release "$ko_v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/ko-app/v1.2.3 \
  GITHUB_REF_NAME=ko-app/v1.2.3 GITHUB_REF_TYPE=tag TRUSTED=true
assert_json "$(matrix publish_matrix)" '.[0] | [.ref_tag, .sha_tag] | join("|")' "v1.2.3|$SHA"
assert_json "$(matrix smoke_matrix)" '[.[].expected_version] | unique | join(",")' 'v1.2.3'
assert_json "$(matrix manifest_matrix)" 'length' '0'

# Release tag: ko env gets the version and drops a catalog VERSION; main keeps the catalog value.
ko_version_v2="$TEST_DIR/ko-version-v2.json"
jq '.images["ko-app"].builders.docker.env = ["CGO_ENABLED=0", "VERSION=v0.0.0"]' "$ko_v2" > "$ko_version_v2"
run_plan ko_version_release "$ko_version_v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/ko-app/v1.2.3 \
  GITHUB_REF_NAME=ko-app/v1.2.3 GITHUB_REF_TYPE=tag TRUSTED=true
assert_json "$(matrix publish_matrix)" '.[0].env | split("\n") | join(",")' 'CGO_ENABLED=0,VERSION=v1.2.3'
run_plan ko_version_main "$ko_version_v2" GITHUB_EVENT_NAME=workflow_dispatch TRUSTED=true
assert_json "$(matrix publish_matrix)" '.[0].env | split("\n") | join(",")' 'CGO_ENABLED=0,VERSION=v0.0.0'
run_plan ko_release_untrusted "$ko_v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/ko-app/v1.2.3 \
  GITHUB_REF_NAME=ko-app/v1.2.3 GITHUB_REF_TYPE=tag TRUSTED=false
assert_json "$(matrix build_matrix)" '.[0].env | split("\n") | join(",")' 'CGO_ENABLED=0,VERSION=v1.2.3'

# Builder-level archs and smoke override the image-level values.
ko_amd="$TEST_DIR/ko-amd.json"
jq '.images["ko-app"].builders.docker.archs = ["amd64"]
    | .images["ko-app"].builders.docker.smoke = {"commands": ["/ko-app --version"]}' "$ko_v2" > "$ko_amd"
run_plan ko_amd64 "$ko_amd" GITHUB_EVENT_NAME=workflow_dispatch TRUSTED=true
assert_json "$(matrix publish_matrix)" '.[0].archs' 'amd64'
assert_json "$(matrix smoke_matrix)" 'length' '1'
assert_json "$(matrix smoke_matrix)" '.[0] | [.id, .arch, .runner] | join("|")' 'ko-app-ko-amd64|amd64|ubuntu-24.04'
assert_json "$(matrix smoke_matrix)" '.[0].smoke_commands | fromjson | join(" ")' '/ko-app --version'
assert_json "$(matrix smoke_matrix)" '.[0].expected_version' ''

# Pre-build hook pairs are exported to the ko build, ahead of the catalog env.
ko_hook_dir="$TEST_DIR/ko-hook"
mkdir -p "$ko_hook_dir/scripts"
printf '#!/usr/bin/env bash\necho KO_HOOK=yes\n' > "$ko_hook_dir/scripts/hook.sh"
jq '.hooks = {"pre_build": "scripts/hook.sh"}' "$ko_v2" > "$ko_hook_dir/catalog.json"
pushd "$ko_hook_dir" >/dev/null
run_plan ko_hook catalog.json GITHUB_EVENT_NAME=workflow_dispatch TRUSTED=true
popd >/dev/null
assert_json "$(matrix publish_matrix)" '.[0].env | split("\n") | join(",")' 'KO_HOOK=yes,CGO_ENABLED=0'

# Invalid ko configuration fails the plan.
for change in \
  '.images["ko-app"].builders.docker.importpath = ""' \
  '.images["ko-app"].builders.docker.env = ["NOT_KEY_VALUE"]' \
  '.images["ko-app"].builders.docker.mode = "pulumi"'; do
  jq "$change" "$ko_v2" > "$TEST_DIR/ko-bad.json"
  if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/ko-bad.out" GITHUB_EVENT_NAME=workflow_dispatch \
      GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
      bash "$PLAN" "$TEST_DIR/ko-bad.json" > "$TEST_DIR/ko-bad.log" 2>&1; then
    fail "planner accepted invalid ko configuration: $change"
  fi
done

# --- Legacy images.json with mode ko -----------------------------------------------

legacy_ko_dir="$TEST_DIR/legacy-ko"
mkdir -p "$legacy_ko_dir/.github"
pushd "$legacy_ko_dir" >/dev/null
cat > .github/images.json <<'JSON'
{
  "registry": "registry.example.invalid/images",
  "images": {
    "legacy-ko": {
      "mode": "ko",
      "ko_working_directory": "svc",
      "ko_importpath": "./cmd/svc",
      "ko_go_version_file": "svc/go.mod",
      "env": "CGO_ENABLED=0\nGOFLAGS=-mod=mod",
      "paths": ["svc/**"]
    }
  }
}
JSON
run_plan legacy_ko_untrusted .github/images.json GITHUB_EVENT_NAME=workflow_dispatch TRUSTED=false
assert_json "$(matrix build_matrix)" 'length' '1'
assert_json "$(matrix build_matrix)" '.[0] | [.mode, .context, .importpath, .ko_config, .go_version_file] | join("|")' 'ko|svc|./cmd/svc|.ko.yaml|svc/go.mod'
assert_json "$(matrix build_matrix)" '.[0].env | split("\n") | join(",")' 'CGO_ENABLED=0,GOFLAGS=-mod=mod'
run_plan legacy_ko_trusted .github/images.json GITHUB_EVENT_NAME=workflow_dispatch TRUSTED=true
assert_json "$(matrix publish_matrix)" '.[0] | [.kind, .id, .archs] | join("|")' 'ko|legacy-ko-ko|amd64,arm64'
assert_json "$(matrix manifest_matrix)" 'length' '0'
assert_json "$(matrix smoke_matrix)" 'length' '0'
popd >/dev/null

# Legacy env is accepted for ko only; other legacy modes still reject it.
echo '{"registry": "registry.example.invalid/images", "images": {"plain": {"env": "A=1", "paths": ["x/**"]}}}' > "$TEST_DIR/legacy-env.json"
if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/legacy-env.out" GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
    bash "$PLAN" "$TEST_DIR/legacy-env.json" > "$TEST_DIR/legacy-env.log" 2>&1; then
  fail "legacy env was accepted for a build mode image"
fi

# --- Negated path patterns -----------------------------------------------------------

neg_repo="$TEST_DIR/neg-repo"
mkdir -p "$neg_repo/.github" "$neg_repo/svc/docs" "$neg_repo/docs/private"
git -C "$neg_repo" init -q
git -C "$neg_repo" config user.email test@example.invalid
git -C "$neg_repo" config user.name test
cat > "$neg_repo/.github/images.json" <<'JSON'
{
  "version": 2,
  "registry": "registry.example.invalid/images",
  "shared_paths": ["!docs/**", "go.mod"],
  "images": {
    "svc": {
      "builders": {"docker": {"context": "svc", "dockerfile": "Dockerfile"}},
      "paths": ["svc/**", "!svc/docs/**", "!svc/README.md"],
      "smoke": {"commands": ["svc --version"]}
    },
    "web": {
      "builders": {"docker": {"dockerfile": "Dockerfile"}},
      "paths": ["docs/**", "!docs/private/**"],
      "smoke": {"commands": ["web --version"]}
    }
  }
}
JSON
echo base > "$neg_repo/svc/main.go"
echo base > "$neg_repo/svc/README.md"
echo base > "$neg_repo/svc/docs/guide.md"
echo base > "$neg_repo/docs/index.md"
echo base > "$neg_repo/docs/private/notes.md"
echo base > "$neg_repo/go.mod"
git -C "$neg_repo" add -A
git -C "$neg_repo" commit -q -m base
neg_base=$(git -C "$neg_repo" rev-parse HEAD)

neg_change() {
  local name="$1"
  shift
  local file
  for file in "$@"; do
    printf '\n' >> "$neg_repo/$file"
  done
  git -C "$neg_repo" add -A
  git -C "$neg_repo" commit -q -m "$name"
  local head_sha
  head_sha=$(git -C "$neg_repo" rev-parse HEAD)
  printf '{"pull_request":{"base":{"sha":"%s"},"head":{"sha":"%s"}}}' "$neg_base" "$head_sha" > "$TEST_DIR/neg-$name.json"
  pushd "$neg_repo" >/dev/null
  run_plan "neg-$name" .github/images.json GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/2/merge \
    GITHUB_REF_NAME=2/merge GITHUB_REF_TYPE=branch GITHUB_SHA="$head_sha" \
    GITHUB_EVENT_PATH="$TEST_DIR/neg-$name.json" TRUSTED=false
  popd >/dev/null
  git -C "$neg_repo" reset -q --hard "$neg_base"
}

neg_change excluded-only svc/docs/guide.md
assert_eq "$(out_value "$OUT" selected_images)" "" "file only under a negated path selects nothing"
neg_change excluded-readme svc/README.md
assert_eq "$(out_value "$OUT" selected_images)" "" "negated exact file selects nothing"
neg_change positive svc/main.go
assert_eq "$(out_value "$OUT" selected_images)" "svc" "file under a positive path selects its image"
neg_change mixed svc/docs/guide.md svc/main.go
assert_eq "$(out_value "$OUT" selected_images)" "svc" "mixed change set selects through the positive file"
neg_change web-positive docs/index.md
assert_eq "$(out_value "$OUT" selected_images)" "web" "negated shared pattern does not plan the full catalog"
neg_change web-excluded docs/private/notes.md
assert_eq "$(out_value "$OUT" selected_images)" "" "negated sub-path inside a positive path selects nothing"
neg_change shared go.mod
assert_eq "$(out_value "$OUT" selected_images)" "svc,web" "positive shared path still plans the full catalog"

# --- Package submodules ---------------------------------------------------------------

# expect_plan_error <name> <catalog> <message> [env assignments...]
expect_plan_error() {
  local name="$1" cfg="$2" msg="$3"
  shift 3
  OUT="$TEST_DIR/$name.out"
  : > "$OUT"
  if env -i PATH="$PATH" HOME="${HOME:-/tmp}" GITHUB_OUTPUT="$OUT" "${DEFAULT_ENV[@]}" "$@" \
      bash "$PLAN" "$cfg" > "$TEST_DIR/$name.log" 2>&1; then
    fail "planner accepted $name"
  fi
  grep -q -- "$msg" "$TEST_DIR/$name.log" || fail "$name: missing error '$msg'"
}

CALLER=GITHUB_REPOSITORY=ethereum-optimism/caller
sub_base="$TEST_DIR/sub-base.json"
write_v2_catalog "$sub_base"

run_plan sub_default "$sub_base" "$CALLER" TRUSTED=true
assert_json "$(matrix packages_matrix)" '.[0] | has("caller_submodules")' 'false'
assert_json "$(matrix packages_matrix)" '.[0].checkout_source' 'false'

sub_true="$TEST_DIR/sub-true.json"
jq '.packages.stack.submodules = true' "$sub_base" > "$sub_true"
run_plan sub_true "$sub_true" "$CALLER" TRUSTED=true
assert_json "$(matrix packages_matrix)" '.[0].caller_submodules' 'true'
assert_json "$(matrix packages_matrix)" '.[0].checkout_source' 'false'

sub_recursive="$TEST_DIR/sub-recursive.json"
jq '.packages.stack.submodules = "recursive"' "$sub_base" > "$sub_recursive"
run_plan sub_recursive "$sub_recursive" "$CALLER" TRUSTED=false
assert_json "$(matrix packages_matrix)" '[.[].caller_submodules] | unique | join(",")' 'recursive'
assert_json "$(matrix packages_matrix)" '[.[].arch] | join(",")' 'x86_64'

sub_false="$TEST_DIR/sub-false.json"
jq '.packages.stack.submodules = "false"' "$sub_base" > "$sub_false"
run_plan sub_false "$sub_false" "$CALLER" TRUSTED=true
assert_json "$(matrix packages_matrix)" '.[0] | has("caller_submodules")' 'false'

# Legacy path "." for the calling repository maps to submodules.
sub_self="$TEST_DIR/sub-self.json"
jq '.packages.stack += {"source": {"repository": "ethereum-optimism/caller", "path": "."}, "source_submodules": "recursive"}' \
  "$sub_base" > "$sub_self"
run_plan sub_self "$sub_self" "$CALLER" TRUSTED=true
assert_json "$(matrix packages_matrix)" '.[0].caller_submodules' 'recursive'
assert_json "$(matrix packages_matrix)" '.[0].checkout_source' 'false'
assert_json "$(matrix packages_matrix)" '.[0].source_path' '.'

sub_self_empty_repo="$TEST_DIR/sub-self-empty-repo.json"
jq '.packages.stack += {"source": {"path": "."}, "source_submodules": "true"}' "$sub_base" > "$sub_self_empty_repo"
run_plan sub_self_empty_repo "$sub_self_empty_repo" "$CALLER" TRUSTED=true
assert_json "$(matrix packages_matrix)" '.[0].caller_submodules' 'true'
assert_json "$(matrix packages_matrix)" '.[0].checkout_source' 'false'

# Legacy v1 catalog with the same source maps to submodules.
legacy_doc="$TEST_DIR/legacy-doc.json"
legacy_apko="$TEST_DIR/legacy-apko.json"
write_legacy_docker "$legacy_doc"
write_legacy_apko "$legacy_apko"
jq '.melange.stack += {"source": {"repository": "ethereum-optimism/caller", "path": "."}, "source_submodules": "recursive"}' \
  "$legacy_apko" > "$legacy_apko.tmp" && mv "$legacy_apko.tmp" "$legacy_apko"
run_plan legacy_self "$legacy_doc" "$CALLER" LEGACY_APKO_CONFIG="$legacy_apko" TRUSTED=true
assert_json "$(matrix packages_matrix)" '[.[] | select(.package == "stack")][0].caller_submodules' 'recursive'
assert_json "$(matrix packages_matrix)" '[.[] | select(.package == "stack")][0].checkout_source' 'false'

bad_value="$TEST_DIR/sub-bad-value.json"
jq '.packages.stack.submodules = "yes"' "$sub_base" > "$bad_value"
expect_plan_error sub_bad_value "$bad_value" "submodules must be false, true, or recursive" "$CALLER" TRUSTED=true

other_sub="$TEST_DIR/sub-other.json"
jq '.packages.stack += {"source": {"repository": "ethereum-optimism/other", "path": "src"}, "submodules": "true"}' \
  "$sub_base" > "$other_sub"
expect_plan_error sub_with_other_source "$other_sub" "submodules applies only to the calling repository checkout" \
  "$CALLER" TRUSTED=true

# Other-repository path "." is built as a source checkout under .package-sources/<package>
# with source.root, so the checkout never replaces the caller's workspace.
ROOT_DIR=.package-sources/stack

other_root="$TEST_DIR/sub-other-root.json"
jq '.packages.stack += {"source": {"repository": "ethereum-optimism/other", "path": "."}}' "$sub_base" > "$other_root"
run_plan sub_other_root "$other_root" "$CALLER" TRUSTED=true
assert_json "$(matrix packages_matrix)" '.[0].checkout_source' 'true'
assert_json "$(matrix packages_matrix)" '.[0].source_repository' 'ethereum-optimism/other'
assert_json "$(matrix packages_matrix)" '.[0].source_path' "$ROOT_DIR"
assert_json "$(matrix packages_matrix)" '.[0].build_dir' "$ROOT_DIR"
assert_json "$(matrix packages_matrix)" '.[0] | has("caller_submodules")' 'false'

pinned_root="$TEST_DIR/sub-pinned-root.json"
jq '.packages.stack += {"source": {"repository": "ethereum-optimism/caller", "path": ".", "ref": "v1.0.0"}}' \
  "$sub_base" > "$pinned_root"
run_plan sub_pinned_root "$pinned_root" "$CALLER" TRUSTED=true
assert_json "$(matrix packages_matrix)" '.[0].checkout_source' 'true'
assert_json "$(matrix packages_matrix)" '.[0].source_ref' 'v1.0.0'
assert_json "$(matrix packages_matrix)" '.[0].source_path' "$ROOT_DIR"
assert_json "$(matrix packages_matrix)" '.[0].build_dir' "$ROOT_DIR"

run_plan sub_no_repo_env "$sub_self" TRUSTED=true
assert_json "$(matrix packages_matrix)" '.[0].checkout_source' 'true'
assert_json "$(matrix packages_matrix)" '.[0].source_path' "$ROOT_DIR"
assert_json "$(matrix packages_matrix)" '.[0].build_dir' "$ROOT_DIR"

# Legacy v1 catalog with an other-repository path "." is built as a root source.
legacy_other_apko="$TEST_DIR/legacy-other-apko.json"
write_legacy_apko "$legacy_other_apko"
jq '.melange.stack += {"source": {"repository": "ethereum-optimism/other", "path": "."}, "source_submodules": "recursive"}' \
  "$legacy_other_apko" > "$legacy_other_apko.tmp" && mv "$legacy_other_apko.tmp" "$legacy_other_apko"
run_plan legacy_other "$legacy_doc" "$CALLER" LEGACY_APKO_CONFIG="$legacy_other_apko" TRUSTED=true
assert_json "$(matrix packages_matrix)" '[.[] | select(.package == "stack")][0].build_dir' "$ROOT_DIR"
assert_json "$(matrix packages_matrix)" '[.[] | select(.package == "stack")][0].source_submodules' 'recursive'
assert_json "$(matrix packages_matrix)" '[.[] | select(.package == "stack")][0] | has("caller_submodules")' 'false'

# An explicit root on a subdirectory checkout builds from that subdirectory.
root_subdir="$TEST_DIR/root-subdir.json"
jq '.packages.stack += {"source": {"repository": "ethereum-optimism/other", "path": "tools", "root": true}}' \
  "$sub_base" > "$root_subdir"
run_plan root_subdir "$root_subdir" "$CALLER" TRUSTED=true
assert_json "$(matrix packages_matrix)" '.[0].source_path' 'tools'
assert_json "$(matrix packages_matrix)" '.[0].build_dir' 'tools'

# A subdirectory source without root keeps the workspace as the build directory.
plain_subdir="$TEST_DIR/plain-subdir.json"
jq '.packages.stack += {"source": {"repository": "ethereum-optimism/other", "path": "tools", "root": false}}' \
  "$sub_base" > "$plain_subdir"
run_plan plain_subdir "$plain_subdir" "$CALLER" TRUSTED=true
assert_json "$(matrix packages_matrix)" '.[0].source_path' 'tools'
assert_json "$(matrix packages_matrix)" '.[0] | has("build_dir")' 'false'

root_false_root="$TEST_DIR/root-false-root.json"
jq '.packages.stack += {"source": {"repository": "ethereum-optimism/other", "path": ".", "root": false}}' \
  "$sub_base" > "$root_false_root"
expect_plan_error root_false_root "$root_false_root" "needs source.root: true" "$CALLER" TRUSTED=true

root_not_bool="$TEST_DIR/root-not-bool.json"
jq '.packages.stack += {"source": {"repository": "ethereum-optimism/other", "path": "tools", "root": "yes"}}' \
  "$sub_base" > "$root_not_bool"
expect_plan_error root_not_bool "$root_not_bool" "source.root must be true or false" "$CALLER" TRUSTED=true

root_self="$TEST_DIR/root-self.json"
jq '.packages.stack += {"source": {"repository": "ethereum-optimism/caller", "path": ".", "root": true}}' \
  "$sub_base" > "$root_self"
expect_plan_error root_self "$root_self" "does not apply to the calling repository checkout" "$CALLER" TRUSTED=true

echo "plan-images tests passed"
