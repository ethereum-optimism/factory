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

# Release tag for an apko image: every variant smoke tests and verifies the version.
run_plan release_gadget "$v2" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/gadget/v3.0.0 \
  GITHUB_REF_NAME=gadget/v3.0.0 GITHUB_REF_TYPE=tag TRUSTED=true
gadget_pub=$(matrix publish_matrix)
assert_json "$gadget_pub" 'length' '2'
assert_json "$(matrix smoke_matrix)" '[.[].expected_version] | unique | join(",")' 'v3.0.0'
assert_json "$(matrix smoke_matrix)" '[.[].id] | sort | join(",")' 'gadget-apko-amd64,gadget-apko-arm64,gadget-apko-dev-amd64,gadget-apko-dev-arm64'
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
assert_json "$(matrix smoke_matrix)" '[.[].id] | sort | join(",")' 'gadget-apko-amd64,gadget-apko-dev-amd64'
assert_json "$(matrix packages_matrix)" 'length' '1'
# The legacy fixture builds amd64 only, so no arm64 smoke leg is planned.
assert_json "$(matrix smoke_matrix)" 'length' '2'
assert_json "$(matrix smoke_matrix)" '[.[].arch] | unique | join(",")' 'amd64'

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

many_files=()
for i in $(seq 1 3000); do
  many_files+=("widget/many/$(printf 'changed-file-with-a-long-name-%0200d' "$i").txt")
done
mkdir -p "$repo/widget/many"
for file in "${many_files[@]}"; do
  echo "$file" > "$repo/$file"
done
pr_change many-files widget/b.txt
assert_eq "$(out_value "$OUT" selected_images)" "widget" "a PR with thousands of changed files still plans"
assert_eq "$(grep -c '^widget/' "$TEST_DIR/pr-many-files.log")" "50" "the changed file listing stops at 50 lines"

# push_change <name> <file> <trusted>: a push to refs/heads/main with a diff against base_sha.
push_change() {
  local name="$1" file="$2" trusted="$3"
  mkdir -p "$(dirname "$repo/$file")"
  printf '\n' >> "$repo/$file"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$name"
  local head_sha
  head_sha=$(git -C "$repo" rev-parse HEAD)
  printf '{"before":"%s","after":"%s"}' "$base_sha" "$head_sha" > "$TEST_DIR/event-push-$name.json"
  pushd "$repo" >/dev/null
  run_plan "push-$name" .github/images.json GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
    GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch GITHUB_SHA="$head_sha" \
    GITHUB_EVENT_PATH="$TEST_DIR/event-push-$name.json" TRUSTED="$trusted"
  popd >/dev/null
  git -C "$repo" reset -q --hard "$base_sha"
}

push_change untrusted-widget widget/b.txt false
assert_eq "$(out_value "$OUT" selected_images)" "widget" "untrusted push change selects widget only"

push_change trusted-widget widget/b.txt true
assert_eq "$(out_value "$OUT" selected_images)" "widget" "default branch push plans only the changed image"
assert_json "$(matrix build_matrix)" 'length' '0'
assert_json "$(matrix publish_matrix)" '[.[].image] | unique | join(",")' 'widget'
assert_json "$(matrix packages_matrix)" 'length' '0'

push_change trusted-gadget gadget/b.txt true
assert_eq "$(out_value "$OUT" selected_images)" "gadget" "default branch push plans the changed apko image"
assert_json "$(matrix packages_matrix)" '[.[].package] | join(",")' 'stack'
assert_json "$(matrix publish_matrix)" '[.[].image] | unique | join(",")' 'gadget'

push_change trusted-package melange/stack.yaml true
assert_eq "$(out_value "$OUT" selected_images)" "gadget" "default branch push of a package plans its images"

push_change trusted-shared go.mod true
assert_eq "$(out_value "$OUT" selected_images)" "gadget,widget" "default branch push of a shared path plans every image"

push_change trusted-catalog .github/images.json true
assert_eq "$(out_value "$OUT" selected_images)" "gadget,widget" "default branch push of the catalog plans every image"

push_change trusted-unrelated docs/readme.md true
assert_eq "$(out_value "$OUT" selected_images)" "" "default branch push with an unrelated change plans nothing"
assert_eq "$(out_value "$OUT" has_publish)" "false" "unrelated default branch push publishes nothing"

# A push whose before SHA is all zeros has no base: the full catalog is planned.
printf '\n' >> "$repo/widget/b.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m new-branch
zero_head=$(git -C "$repo" rev-parse HEAD)
printf '{"before":"%s","after":"%s"}' "0000000000000000000000000000000000000000" "$zero_head" > "$TEST_DIR/event-push-zero.json"
pushd "$repo" >/dev/null
run_plan push-zero .github/images.json GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch GITHUB_SHA="$zero_head" \
  GITHUB_EVENT_PATH="$TEST_DIR/event-push-zero.json" TRUSTED=true
popd >/dev/null
git -C "$repo" reset -q --hard "$base_sha"
assert_eq "$(out_value "$OUT" selected_images)" "gadget,widget" "a push without a base plans every image"
grep -q 'Could not compute the changed files' "$TEST_DIR/push-zero.log" || fail "push without a base: missing fallback warning"

# A push whose before SHA is not in the repository falls back to the full catalog.
printf '{"before":"%s","after":"%s"}' "1111111111111111111111111111111111111111" "$base_sha" > "$TEST_DIR/event-push-missing.json"
pushd "$repo" >/dev/null
run_plan push-missing .github/images.json GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch GITHUB_SHA="$base_sha" \
  GITHUB_EVENT_PATH="$TEST_DIR/event-push-missing.json" TRUSTED=true
popd >/dev/null
assert_eq "$(out_value "$OUT" selected_images)" "gadget,widget" "a push with an unknown base plans every image"

# Schedules and dispatches without a target rebuild the full catalog.
pushd "$repo" >/dev/null
run_plan schedule-full .github/images.json GITHUB_EVENT_NAME=schedule GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch GITHUB_SHA="$base_sha" TRUSTED=true
assert_eq "$(out_value "$OUT" selected_images)" "gadget,widget" "schedule plans every image"
run_plan dispatch-full .github/images.json GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch GITHUB_SHA="$base_sha" TRUSTED=true TARGET=
assert_eq "$(out_value "$OUT" selected_images)" "gadget,widget" "dispatch without a target plans every image"
popd >/dev/null

# --- Dispatch target ------------------------------------------------------------------

run_plan target_widget "$v2" TRUSTED=true TARGET=widget
assert_eq "$(out_value "$OUT" selected_images)" "widget" "target plans only the named image"
assert_json "$(matrix packages_matrix)" 'length' '0'
assert_json "$(matrix publish_matrix)" '[.[].image] | unique | join(",")' 'widget'

run_plan target_gadget "$v2" TRUSTED=true TARGET=gadget
assert_eq "$(out_value "$OUT" selected_images)" "gadget" "target plans the named apko image"
assert_eq "$(out_value "$OUT" selected_packages)" "stack" "target plans the packages of the image"

run_plan target_untrusted "$v2" TRUSTED=false TARGET=widget GITHUB_REF=refs/heads/feature GITHUB_REF_NAME=feature
assert_eq "$(out_value "$OUT" selected_images)" "widget" "untrusted dispatch target plans only the named image"
assert_json "$(matrix build_matrix)" '[.[].image] | unique | join(",")' 'widget'
assert_json "$(matrix publish_matrix)" 'length' '0'

target_reject() {
  local name="$1" target="$2" msg="$3"
  shift 3
  OUT="$TEST_DIR/$name.out"
  : > "$OUT"
  if env -i PATH="$PATH" HOME="${HOME:-/tmp}" GITHUB_OUTPUT="$OUT" "${DEFAULT_ENV[@]}" TRUSTED=true TARGET="$target" "$@" \
      bash "$PLAN" "$v2" > "$TEST_DIR/$name.log" 2>&1; then
    fail "planner accepted $name"
  fi
  grep -q -- "$msg" "$TEST_DIR/$name.log" || fail "$name: missing error '$msg'"
  [[ -s "$OUT" ]] && fail "$name: planner emitted outputs"
  return 0
}
target_reject target_unknown nope "is not an image in the catalog"
target_reject target_bad_name '../widget' "is not an image in the catalog"
target_reject target_on_push widget "applies only to workflow_dispatch" GITHUB_EVENT_NAME=push
target_reject target_on_tag widget "does not apply to runs on a tag ref" GITHUB_REF=refs/tags/widget/v1.2.3 \
  GITHUB_REF_NAME=widget/v1.2.3 GITHUB_REF_TYPE=tag

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
assert_json "$(matrix packages_matrix)" '[.[].runner] | unique | join(",")' 'oplabs-ubuntu-x86'
assert_json "$(matrix packages_matrix)" '[.[] | has("free_disk")] | unique | join(",")' 'false'
run_plan untrusted_standard "$v2" GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge \
  GITHUB_REF_NAME=1/merge GITHUB_REF_TYPE=branch TRUSTED=false
assert_json "$(matrix packages_matrix)" '[.[].runner] | unique | join(",")' 'ubuntu-24.04'
assert_json "$(matrix packages_matrix)" '[.[] | has("free_disk")] | unique | join(",")' 'false'
run_plan trusted_large "$large" TRUSTED=true
assert_json "$(matrix packages_matrix)" '[.[] | has("free_disk")] | unique | join(",")' 'false'
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

# --- Default-branch alias tags -----------------------------------------------

alias_cat="$TEST_DIR/alias.json"
cat > "$alias_cat" <<'JSON'
{
  "version": 2,
  "registry": "registry.example.invalid/images",
  "default_branch_tags": ["latest"],
  "packages": {
    "stack": {"config": "melange/stack.yaml", "archs": ["x86_64", "aarch64"]}
  },
  "images": {
    "both": {
      "builders": {
        "docker": {"dockerfile": "Dockerfile"},
        "apko": {
          "needs_packages": ["stack"],
          "configs": [
            {"config": "apko/both.yaml", "tag_suffix": ""},
            {"config": "apko/both-dev.yaml", "tag_suffix": "-dev"}
          ]
        }
      },
      "primary": "docker",
      "paths": ["both/**"],
      "smoke": {"commands": ["/bin/sh -c true"]}
    },
    "solo": {
      "builders": {"docker": {"dockerfile": "Dockerfile"}},
      "paths": ["solo/**"],
      "default_branch_tags": ["stable", "latest"]
    },
    "optout": {
      "builders": {"docker": {"dockerfile": "Dockerfile"}},
      "paths": ["optout/**"],
      "default_branch_tags": []
    }
  }
}
JSON

run_plan alias_main "$alias_cat" TRUSTED=true
assert_json "$(matrix publish_matrix)" '[.[] | select(.id == "both-apko") | .alias_tags] | join(",")' 'apko-latest'
assert_json "$(matrix publish_matrix)" '[.[] | select(.id == "both-apko-dev") | .alias_tags] | join(",")' 'apko-latest-dev'
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | has("alias_tags")] | any' 'false'
assert_json "$(matrix manifest_matrix)" '[.[] | select(.id == "both-docker") | .alias_tags] | join(",")' 'latest'
assert_json "$(matrix manifest_matrix)" '[.[] | select(.id == "solo-docker") | .alias_tags] | join(",")' 'stable,latest'
assert_json "$(matrix manifest_matrix)" '[.[] | select(.id == "optout-docker") | has("alias_tags")] | any' 'false'
assert_json "$(matrix manifest_matrix)" '[.[] | select(.id == "solo-docker") | .ref_tag] | join(",")' 'main'

run_plan alias_feature "$alias_cat" TRUSTED=false GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/feature \
  GITHUB_REF_NAME=feature GITHUB_REF_TYPE=branch
assert_json "$(matrix publish_matrix)" 'length' '0'
assert_json "$(matrix manifest_matrix)" 'length' '0'

run_plan alias_release "$alias_cat" TRUSTED=true GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/solo/v1.2.3 \
  GITHUB_REF_NAME=solo/v1.2.3 GITHUB_REF_TYPE=tag
assert_json "$(matrix manifest_matrix)" '[.[] | has("alias_tags")] | any' 'false'
assert_json "$(matrix publish_matrix)" '[.[] | has("alias_tags")] | any' 'false'
assert_json "$(matrix manifest_matrix)" '.[0].ref_tag' 'solo-v1.2.3'

run_plan alias_untrusted "$alias_cat" TRUSTED=false GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/9/merge \
  GITHUB_REF_NAME=9/merge GITHUB_REF_TYPE=branch
assert_json "$(matrix publish_matrix)" 'length' '0'
assert_json "$(matrix manifest_matrix)" 'length' '0'

# A catalog without the key and one with an empty list plan the same outputs.
no_key="$TEST_DIR/no-key.json"
empty_key="$TEST_DIR/empty-key.json"
jq 'del(.default_branch_tags) | del(.images[].default_branch_tags)' "$alias_cat" > "$no_key"
jq '.default_branch_tags = [] | del(.images[].default_branch_tags)' "$alias_cat" > "$empty_key"
run_plan no_key "$no_key" TRUSTED=true
cp "$OUT" "$TEST_DIR/no-key.plan"
run_plan empty_key "$empty_key" TRUSTED=true
cmp -s "$TEST_DIR/no-key.plan" "$OUT" || fail "empty default_branch_tags changed the planned outputs"
assert_json "$(matrix publish_matrix)" '[.[] | has("alias_tags")] | any' 'false'

for bad in \
  '.default_branch_tags = [""]' \
  '.default_branch_tags = ["a/b"]' \
  '.default_branch_tags = ["a:b"]' \
  '.default_branch_tags = ["la test"]' \
  '.default_branch_tags = ["latest@x"]' \
  '.default_branch_tags = "latest"' \
  '.default_branch_tags = [1]' \
  '.default_branch_tags = [null]' \
  '.images.solo.default_branch_tags = ["a/b"]' \
  '.images.solo.default_branch_tags = "stable"'; do
  jq "$bad" "$alias_cat" > "$TEST_DIR/bad-alias.json"
  : > "$TEST_DIR/bad-alias.out"
  if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/bad-alias.out" GITHUB_EVENT_NAME=workflow_dispatch \
      GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
      bash "$PLAN" "$TEST_DIR/bad-alias.json" > "$TEST_DIR/bad-alias.log" 2>&1; then
    fail "planner accepted invalid default_branch_tags: $bad"
  fi
  if [[ -s "$TEST_DIR/bad-alias.out" ]]; then
    fail "planner emitted outputs for invalid default_branch_tags: $bad"
  fi
done

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

# --- Per-builder runner and event filter ------------------------------------------

write_context_catalog() {
  cat > "$1" <<'JSON'
{
  "version": 2,
  "registry": "registry.example.invalid/images",
  "packages": {
    "stack": {"config": "melange/stack.yaml", "archs": ["x86_64"]}
  },
  "images": {
    "heavy": {
      "builders": {
        "docker": {"dockerfile": "Dockerfile", "runner_profile": "large", "events": ["release", "workflow_dispatch"]}
      },
      "paths": ["heavy/**"]
    },
    "light": {
      "builders": {"docker": {"dockerfile": "Dockerfile"}},
      "paths": ["light/**"]
    },
    "split": {
      "builders": {
        "docker": {"dockerfile": "Dockerfile", "events": ["release"]},
        "apko": {"config": "apko/split.yaml", "needs_packages": ["stack"], "runner_profile": "large"}
      },
      "primary": "docker",
      "paths": ["split/**"]
    },
    "pronly": {
      "builders": {"apko": {"config": "apko/pronly.yaml", "events": ["pull_request"]}},
      "paths": ["pronly/**"]
    }
  }
}
JSON
}

ctx="$TEST_DIR/context.json"
write_context_catalog "$ctx"
PUSH_MAIN=(GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch)
DISPATCH_MAIN=(GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch)
PR_BRANCH=(GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/7/merge GITHUB_REF_NAME=7/merge GITHUB_REF_TYPE=branch)
RELEASE_HEAVY=(GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/heavy/v1.2.3 GITHUB_REF_NAME=heavy/v1.2.3 GITHUB_REF_TYPE=tag)

# Trusted default-branch push: builders limited to release or dispatch are not planned, and an image left without a builder is skipped.
run_plan ctx_push "$ctx" TRUSTED=true "${PUSH_MAIN[@]}"
assert_eq "$(out_value "$OUT" selected_images)" "light,split" "push plans only images with a builder for push"
assert_json "$(matrix publish_matrix)" '[.[].image] | unique | join(",")' 'light,split'
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "split") | .kind] | join(",")' 'apko'
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "split") | .runner] | join(",")' 'oplabs-ubuntu-x86'
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "light") | .runner] | unique | join(",")' 'ubuntu-24.04,ubuntu-24.04-arm'
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "split") | .ref_tag] | join(",")' 'apko-main'

# Scheduled runs plan the full catalog through the same filter.
run_plan ctx_schedule "$ctx" TRUSTED=true GITHUB_EVENT_NAME=schedule GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch
assert_eq "$(out_value "$OUT" selected_images)" "light,split" "schedule plans builders whose events include schedule only"
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "heavy")] | length' '0'

# Dispatch from the default branch includes workflow_dispatch builders.
run_plan ctx_dispatch "$ctx" TRUSTED=true "${DISPATCH_MAIN[@]}"
assert_eq "$(out_value "$OUT" selected_images)" "heavy,light,split" "dispatch plans workflow_dispatch builders"
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "heavy") | .runner] | unique | join(",")' 'oplabs-ubuntu-arm,oplabs-ubuntu-x86'

# Release tag: the image's builders whose events include release are planned, and the rest are not.
run_plan ctx_release "$ctx" TRUSTED=true "${RELEASE_HEAVY[@]}"
assert_eq "$(out_value "$OUT" selected_images)" "heavy" "release tag plans the tagged image"
assert_eq "$(out_value "$OUT" is_release)" "true" "release tag context"
assert_json "$(matrix publish_matrix)" 'sort_by(.arch) | map(.runner) | join(",")' 'oplabs-ubuntu-x86,oplabs-ubuntu-arm'

run_plan ctx_release_split "$ctx" TRUSTED=true GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/split/v1.0.0 \
  GITHUB_REF_NAME=split/v1.0.0 GITHUB_REF_TYPE=tag
assert_eq "$(out_value "$OUT" selected_images)" "split" "release tag for a dual image"
assert_json "$(matrix publish_matrix)" '[.[] | select(.builder == "docker") | .sha_tag] | unique | join(",")' "$SHA"
assert_json "$(matrix publish_matrix)" '[.[] | select(.kind == "apko") | .sha_tag] | join(",")' "apko-$SHA"

# A tagged image with no builder for the release context plans nothing and succeeds.
run_plan ctx_release_pronly "$ctx" TRUSTED=true GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/pronly/v1.0.0 \
  GITHUB_REF_NAME=pronly/v1.0.0 GITHUB_REF_TYPE=tag
assert_eq "$(out_value "$OUT" selected_images)" "" "release tag with no builder for release plans nothing"
assert_json "$(matrix publish_matrix)" 'length' '0'

# Untrusted pull request: pull_request builders are planned, release and dispatch builders are not.
run_plan ctx_pr "$ctx" TRUSTED=false "${PR_BRANCH[@]}"
assert_eq "$(out_value "$OUT" selected_images)" "light,pronly,split" "pull request plans pull_request builders"
assert_json "$(matrix build_matrix)" '[.[] | select(.image == "heavy")] | length' '0'
assert_json "$(matrix build_matrix)" '[.[] | select(.image == "split") | .builder] | unique | join(",")' 'apko'
assert_json "$(matrix build_matrix)" '[.[] | select(.image == "split") | .runner] | unique | join(",")' 'oplabs-ubuntu-x86'
assert_json "$(matrix build_matrix)" '[.[] | select(.image == "light") | .runner] | unique | join(",")' 'ubuntu-24.04'
assert_json "$(matrix build_matrix)" '[.[] | select(.image == "pronly") | .runner] | unique | join(",")' 'ubuntu-24.04'

# Merge queue builds use the pull_request context.
run_plan ctx_merge_group "$ctx" TRUSTED=false GITHUB_EVENT_NAME=merge_group GITHUB_REF=refs/heads/gh-readonly-queue/main/pr-7 \
  GITHUB_REF_NAME=gh-readonly-queue/main/pr-7 GITHUB_REF_TYPE=branch
assert_eq "$(out_value "$OUT" selected_images)" "light,pronly,split" "merge group uses the pull_request context"

# Untrusted plan for a large builder: the build leg runs on the large runner of its profile.
run_plan ctx_untrusted_release "$ctx" TRUSTED=false "${RELEASE_HEAVY[@]}"
assert_eq "$(out_value "$OUT" selected_images)" "heavy" "untrusted release tag plans the tagged image"
assert_json "$(matrix build_matrix)" '[.[].runner] | unique | join(",")' 'oplabs-ubuntu-x86'
assert_json "$(matrix publish_matrix)" 'length' '0'
assert_json "$(matrix smoke_matrix)" 'length' '0'

# Primary builder filtered out for the context: the remaining builder keeps the tag prefix it has when both run.
primary_apko="$TEST_DIR/primary-apko.json"
jq '.images.split.primary = "apko" | .images.split.builders.apko.events = ["release"] | .images.split.builders.docker.events = ["push"]' \
  "$ctx" > "$primary_apko"
run_plan ctx_primary_filtered "$primary_apko" TRUSTED=true "${PUSH_MAIN[@]}"
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "split") | .builder] | unique | join(",")' 'docker'
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "split") | .sha_tag] | unique | join(",")' "docker-$SHA"

run_plan ctx_primary_docker "$ctx" TRUSTED=true "${PUSH_MAIN[@]}"
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "split") | .kind] | unique | join(",")' 'apko'
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "split") | .sha_tag] | unique | join(",")' "apko-$SHA"

# Invalid runner_profile and events values fail the plan before any output.
for change in \
  '.images.heavy.builders.docker.runner_profile = "audit-test-runner"' \
  '.images.light.builders.docker.runner_profile = "oplabs-ubuntu-x86"' \
  '.images.split.builders.apko.runner_profile = null' \
  '.images.split.builders.apko.runner_profile = ["large"]' \
  '.images.light.builders.docker.events = "push"' \
  '.images.light.builders.docker.events = []' \
  '.images.light.builders.docker.events = null' \
  '.images.light.builders.docker.events = ["merge_group"]' \
  '.images.light.builders.docker.events = ["push", "tag"]' \
  '.images.split.builders.apko.events = [1]'; do
  jq "$change" "$ctx" > "$TEST_DIR/rejected-ctx.json"
  : > "$TEST_DIR/rejected-ctx.out"
  if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/rejected-ctx.out" "${PUSH_MAIN[@]}" TRUSTED=true \
      bash "$PLAN" "$TEST_DIR/rejected-ctx.json" > "$TEST_DIR/rejected-ctx.log" 2>&1; then
    fail "planner accepted invalid builder configuration: $change"
  fi
  if [[ -s "$TEST_DIR/rejected-ctx.out" ]]; then
    fail "planner emitted outputs for invalid builder configuration: $change"
  fi
done

# --- Commit and date build arguments ---------------------------------------------------

git_repo="$TEST_DIR/git-build-args"
mkdir -p "$git_repo/widget"
git -C "$git_repo" init -q
git -C "$git_repo" config user.email test@example.invalid
git -C "$git_repo" config user.name test
echo base > "$git_repo/widget/a.txt"
git -C "$git_repo" add -A
GIT_AUTHOR_DATE="2026-11-18T09:00:00Z" GIT_COMMITTER_DATE="2026-11-19T13:00:00+01:00" \
  git -C "$git_repo" commit -q -m base
git_sha=$(git -C "$git_repo" rev-parse HEAD)
git_date="2026-11-19T13:00:00+01:00"

# Without the flag, catalog values pass through and the key itself changes nothing.
stale_v2="$TEST_DIR/stale-v2.json"
jq '.images.widget.builders.docker.build_args = {"GIT_COMMIT": "stale", "GIT_DATE": "stale", "FOO": "bar"}' "$v2" > "$stale_v2"
false_v2="$TEST_DIR/false-v2.json"
jq '.images.widget.builders.docker.git_build_args = false' "$stale_v2" > "$false_v2"
pushd "$git_repo" >/dev/null
run_plan git_flag_absent "$stale_v2" GITHUB_SHA="$git_sha" GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true
cp "$OUT" "$TEST_DIR/git-flag-absent.saved"
run_plan git_flag_false "$false_v2" GITHUB_SHA="$git_sha" GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true
cmp -s "$OUT" "$TEST_DIR/git-flag-absent.saved" || fail "git_build_args false changed the plan outputs"
assert_json "$(matrix publish_matrix)" "$widget_docker_args" 'FOO=bar,GIT_COMMIT=stale,GIT_DATE=stale'

# Flag on: build legs (untrusted), publish legs (trusted push), and release tags all get the commit and committer date.
git_v2="$TEST_DIR/git-v2.json"
jq '.images.widget.builders.docker.build_args = {"GIT_COMMIT": "stale", "GIT_DATE": "stale", "FOO": "bar"}
    | .images.widget.builders.docker.git_build_args = true' "$v2" > "$git_v2"
expected_args="FOO=bar,GIT_COMMIT=$git_sha,GIT_DATE=$git_date"
run_plan git_untrusted "$git_v2" GITHUB_SHA="$git_sha" GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=false
assert_json "$(matrix build_matrix)" "$widget_docker_args" "$expected_args"
run_plan git_trusted "$git_v2" GITHUB_SHA="$git_sha" GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true
assert_json "$(matrix publish_matrix)" "$widget_docker_args" "$expected_args"
run_plan git_release "$git_v2" GITHUB_SHA="$git_sha" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/widget/v1.2.3 \
  GITHUB_REF_NAME=widget/v1.2.3 GITHUB_REF_TYPE=tag TRUSTED=true
assert_json "$(matrix publish_matrix)" "$widget_docker_args" "$expected_args,VERSION=v1.2.3"
run_plan git_release_untrusted "$git_v2" GITHUB_SHA="$git_sha" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/widget/v1.2.3 \
  GITHUB_REF_NAME=widget/v1.2.3 GITHUB_REF_TYPE=tag TRUSTED=false
assert_json "$(matrix build_matrix)" "$widget_docker_args" "$expected_args,VERSION=v1.2.3"

# Flag on for ko: the pair goes into env, replacing catalog copies.
git_ko="$TEST_DIR/git-ko.json"
jq '.images["ko-app"].builders.docker.env = ["CGO_ENABLED=0", "GIT_COMMIT=stale"]
    | .images["ko-app"].builders.docker.git_build_args = true' "$ko_v2" > "$git_ko"
run_plan git_ko_untrusted "$git_ko" GITHUB_SHA="$git_sha" GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=false
assert_json "$(matrix build_matrix)" '.[0].env | split("\n") | join(",")' "CGO_ENABLED=0,GIT_COMMIT=$git_sha,GIT_DATE=$git_date"
run_plan git_ko_trusted "$git_ko" GITHUB_SHA="$git_sha" GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true
assert_json "$(matrix publish_matrix)" '.[0].env | split("\n") | join(",")' "CGO_ENABLED=0,GIT_COMMIT=$git_sha,GIT_DATE=$git_date"
popd >/dev/null

# Flag on without a commit in the checkout fails the plan.
mkdir -p "$TEST_DIR/no-git"
pushd "$TEST_DIR/no-git" >/dev/null
if env -i PATH="$PATH" HOME="${HOME:-/tmp}" GITHUB_OUTPUT="$TEST_DIR/no-git.out" GITHUB_SHA="$git_sha" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch \
    TRUSTED=true bash "$PLAN" "$git_v2" > "$TEST_DIR/no-git.log" 2>&1; then
  fail "planner accepted git_build_args without a commit in the checkout"
fi
grep -q 'git_build_args needs commit' "$TEST_DIR/no-git.log" || fail "missing git_build_args commit error"
popd >/dev/null

# Bake mode and non-boolean values are rejected.
reject_git_change() {
  local change="$1" want="$2"
  jq "$change" "$v2" > "$TEST_DIR/git-bad.json"
  if env -i PATH="$PATH" GITHUB_OUTPUT="$TEST_DIR/git-bad.out" GITHUB_EVENT_NAME=workflow_dispatch \
      GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch TRUSTED=true \
      bash "$PLAN" "$TEST_DIR/git-bad.json" > "$TEST_DIR/git-bad.log" 2>&1; then
    fail "planner accepted $change"
  fi
  grep -q "$want" "$TEST_DIR/git-bad.log" || fail "missing error '$want' for $change"
}
reject_git_change '.images.widget.builders.docker.mode = "bake" | .images.widget.builders.docker.git_build_args = true' \
  'git_build_args is not supported for mode bake'
reject_git_change '.images.widget.builders.docker.git_build_args = "yes"' \
  'builders.docker.git_build_args must be a boolean'

# --- Per-variant smoke, variant config paths, -slim guard and tags ---------------------

write_slim_configs() {
  mkdir -p "$1/apko"
  cat > "$1/apko/foo.yaml" <<'YAML'
contents:
  packages:
    - busybox
    - apk-tools
    - ca-certificates-bundle
    - foo-bin
YAML
  cat > "$1/apko/foo-slim.yaml" <<'YAML'
contents:
  packages:
    - ca-certificates-bundle
    - foo-bin
YAML
  cat > "$1/apko/bar.yaml" <<'YAML'
contents:
  packages:
    - busybox
    - ca-certificates-bundle
    - bar-bin
YAML
  cat > "$1/apko/bar-slim.yaml" <<'YAML'
contents:
  packages:
    - ca-certificates-bundle
    - bar-bin
YAML
}

write_slim_catalog() {
  cat > "$1" <<'JSON'
{
  "version": 2,
  "registry": "registry.example.invalid/images",
  "default_branch_tags": ["latest"],
  "release": {
    "tag_regex": "^([^/]+)/(v.+)$",
    "service_match": 1,
    "version_match": 2,
    "publish_tag": "${version}",
    "source_ref": "${ref_name}"
  },
  "packages": {
    "stack": {"config": "melange/stack.yaml", "archs": ["x86_64"]}
  },
  "images": {
    "foo": {
      "builders": {
        "apko": {
          "needs_packages": ["stack"],
          "configs": [
            {"config": "apko/foo.yaml", "tag_suffix": ""},
            {"config": "apko/foo-slim.yaml", "tag_suffix": "-slim"}
          ]
        }
      },
      "paths": ["foo/**"],
      "smoke": {"commands": ["foo --version"], "verify_version": true}
    },
    "bar": {
      "builders": {
        "apko": {
          "needs_packages": ["stack"],
          "configs": [
            {"config": "apko/bar.yaml", "tag_suffix": ""},
            {"config": "apko/bar-slim.yaml", "tag_suffix": "-slim", "smoke": {"commands": ["bar-slim --help"]}}
          ]
        }
      },
      "paths": ["bar/**"],
      "smoke": {"commands": ["bar --version"]}
    }
  }
}
JSON
}

slim_repo="$TEST_DIR/slim-repo"
mkdir -p "$slim_repo/.github" "$slim_repo/foo" "$slim_repo/bar" "$slim_repo/melange"
write_slim_catalog "$slim_repo/.github/images.json"
write_slim_configs "$slim_repo"
echo base > "$slim_repo/foo/a.txt"
echo base > "$slim_repo/bar/a.txt"
echo base > "$slim_repo/melange/stack.yaml"
git -C "$slim_repo" init -q
git -C "$slim_repo" config user.email test@example.invalid
git -C "$slim_repo" config user.name test
git -C "$slim_repo" add -A
git -C "$slim_repo" commit -q -m base
slim_base_sha=$(git -C "$slim_repo" rev-parse HEAD)

pushd "$slim_repo" >/dev/null

# Dispatch on the default branch: every variant gets a publish leg, a trusted smoke leg, and -slim tags.
run_plan slim_dispatch .github/images.json TRUSTED=true
assert_json "$(matrix smoke_matrix)" '[.[].id] | sort | join(",")' \
  'bar-apko-amd64,bar-apko-arm64,bar-apko-slim-amd64,bar-apko-slim-arm64,foo-apko-amd64,foo-apko-arm64,foo-apko-slim-amd64,foo-apko-slim-arm64'
assert_json "$(matrix smoke_matrix)" '.[] | select(.id == "foo-apko-slim-amd64") | .smoke_commands | fromjson | join(" ")' 'foo --version'
assert_json "$(matrix smoke_matrix)" '.[] | select(.id == "bar-apko-slim-amd64") | .smoke_commands | fromjson | join(" ")' 'bar-slim --help'
assert_json "$(matrix smoke_matrix)" '.[] | select(.id == "bar-apko-amd64") | .smoke_commands | fromjson | join(" ")' 'bar --version'
assert_json "$(matrix smoke_matrix)" '.[] | select(.id == "foo-apko-slim-amd64") | .final_artifact' 'final-foo-apko-slim'
assert_json "$(matrix smoke_matrix)" '.[] | select(.id == "foo-apko-amd64") | .final_artifact' 'final-foo-apko'
assert_json "$(matrix publish_matrix)" '.[] | select(.id == "foo-apko-slim") | .sha_tag' "${SHA}-slim"
assert_json "$(matrix publish_matrix)" '.[] | select(.id == "foo-apko-slim") | .alias_tags' 'latest-slim'
assert_json "$(matrix publish_matrix)" '.[] | select(.id == "foo-apko") | .alias_tags' 'latest'

# Untrusted pull request run: the build legs smoke every variant on amd64.
run_plan slim_untrusted .github/images.json GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge \
  GITHUB_REF_NAME=1/merge GITHUB_REF_TYPE=branch TRUSTED=false
assert_json "$(matrix build_matrix)" '[.[] | select(.builder == "apko") | .id] | sort | join(",")' \
  'bar-apko,bar-apko-slim,foo-apko,foo-apko-slim'
assert_json "$(matrix build_matrix)" '[.[] | select(.id == "foo-apko-slim") | .has_smoke] | join(",")' 'true'
assert_json "$(matrix build_matrix)" '.[] | select(.id == "foo-apko-slim") | .smoke_commands | fromjson | join(" ")' 'foo --version'
assert_json "$(matrix build_matrix)" '.[] | select(.id == "bar-apko-slim") | .smoke_commands | fromjson | join(" ")' 'bar-slim --help'

# Release tag: the slim publish tag is <version>-slim and smoke carries the release version.
run_plan slim_release .github/images.json GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/foo/v1.2.3 \
  GITHUB_REF_NAME=foo/v1.2.3 GITHUB_REF_TYPE=tag TRUSTED=true
assert_json "$(matrix publish_matrix)" '[.[] | select(.id == "foo-apko-slim") | .ref_tag] | join(",")' 'v1.2.3-slim'
assert_json "$(matrix publish_matrix)" '[.[] | select(.id == "foo-apko") | .ref_tag] | join(",")' 'v1.2.3'
assert_json "$(matrix publish_matrix)" '[.[] | select(.id == "foo-apko-slim") | .alias_tags // ""] | join(",")' ''
assert_json "$(matrix smoke_matrix)" '[.[] | select(.id == "foo-apko-slim-amd64") | .expected_version] | join(",")' 'v1.2.3'
assert_json "$(matrix smoke_matrix)" '[.[] | .image] | unique | join(",")' 'foo'

# Default branch develop: the slim branch tag is develop-slim.
run_plan slim_develop .github/images.json GITHUB_REF=refs/heads/develop GITHUB_REF_NAME=develop TRUSTED=true
assert_json "$(matrix publish_matrix)" '[.[] | select(.id == "foo-apko-slim") | .ref_tag] | join(",")' 'develop-slim'
assert_json "$(matrix publish_matrix)" '[.[] | select(.id == "bar-apko-slim") | .ref_tag] | join(",")' 'develop-slim'

# Config files are change paths: editing a variant config that is not listed in paths selects its image.
slim_change() {
  local name="$1" file="$2"
  mkdir -p "$(dirname "$slim_repo/$file")"
  printf '\n' >> "$slim_repo/$file"
  git -C "$slim_repo" add -A
  git -C "$slim_repo" commit -q -m "$name"
  local head_sha
  head_sha=$(git -C "$slim_repo" rev-parse HEAD)
  printf '{"pull_request":{"base":{"sha":"%s"},"head":{"sha":"%s"}}}' "$slim_base_sha" "$head_sha" > "$TEST_DIR/event-$name.json"
  run_plan "slim-$name" .github/images.json GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge \
    GITHUB_REF_NAME=1/merge GITHUB_REF_TYPE=branch GITHUB_SHA="$head_sha" \
    GITHUB_EVENT_PATH="$TEST_DIR/event-$name.json" TRUSTED=false
  git -C "$slim_repo" reset -q --hard "$slim_base_sha"
}
slim_change foo-slim-config apko/foo-slim.yaml
assert_eq "$(out_value "$OUT" selected_images)" "foo" "foo -slim config change selects foo"
slim_change bar-config apko/bar.yaml
assert_eq "$(out_value "$OUT" selected_images)" "bar" "bar fat config change selects bar"
slim_change unrelated docs/readme.md
assert_eq "$(out_value "$OUT" selected_images)" "" "unrelated change selects nothing"

popd >/dev/null

# -slim guard: apk-tools, busybox, and openssl are rejected unless allow_packages names them.
guard_dir="$TEST_DIR/guard"
mkdir -p "$guard_dir"
pushd "$guard_dir" >/dev/null

# guard_check <name> <pass|fail> <slim packages> [allow_packages JSON array]
guard_check() {
  local name="$1" expect="$2" pkgs="$3" allow="${4:-[]}" p
  mkdir -p apko
  {
    echo "contents:"
    echo "  packages:"
    for p in $pkgs; do echo "    - $p"; done
  } > apko/gd-slim.yaml
  cat > apko/gd.yaml <<'YAML'
contents:
  packages:
    - busybox
    - apk-tools
    - openssl
YAML
  printf '%s' '{"version":2,"registry":"registry.example.invalid/images","packages":{"stack":{"config":"melange/stack.yaml","archs":["x86_64"]}},"images":{"gd":{"builders":{"apko":{"needs_packages":["stack"],"configs":[{"config":"apko/gd.yaml","tag_suffix":""},{"config":"apko/gd-slim.yaml","tag_suffix":"-slim","allow_packages":'"$allow"'}]}},"smoke":{"commands":["gd --version"]}}}}' > "$guard_dir/catalog.json"
  local rc=0
  env -i PATH="$PATH" HOME="${HOME:-/tmp}" GITHUB_OUTPUT="$TEST_DIR/guard-$name.out" GITHUB_SHA="$SHA" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch \
    TRUSTED=true bash "$PLAN" catalog.json > "$TEST_DIR/guard-$name.log" 2>&1 || rc=$?
  if [[ "$expect" == pass ]]; then
    [[ "$rc" -eq 0 ]] || { cat "$TEST_DIR/guard-$name.log" >&2; fail "guard $name rejected a valid -slim variant"; }
  else
    [[ "$rc" -ne 0 ]] || fail "guard $name accepted a -slim variant with a forbidden package"
    grep -q 'must not include apk-tools, busybox, or openssl' "$TEST_DIR/guard-$name.log" \
      || fail "guard $name missing its error message"
  fi
}

guard_check apk-tools fail "ca-certificates-bundle apk-tools"
guard_check busybox-pinned fail "busybox=1.36.1-r0"
guard_check openssl-constraint fail "openssl>=3.0 ca-certificates-bundle"
guard_check openssl-dev fail "openssl-dev"
guard_check clean pass "ca-certificates-bundle foo-bin"
guard_check allowed pass "ca-certificates-bundle busybox=1.36.1-r0 openssl>=3.0" '["busybox=1.36.1-r0","openssl"]'
guard_check partial-allow fail "busybox apk-tools" '["busybox"]'

# A missing -slim config file fails the plan instead of skipping the guard.
rm -f apko/gd-slim.yaml
rc=0
env -i PATH="$PATH" HOME="${HOME:-/tmp}" GITHUB_OUTPUT="$TEST_DIR/guard-missing.out" GITHUB_SHA="$SHA" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch \
  TRUSTED=true bash "$PLAN" "$guard_dir/catalog.json" > "$TEST_DIR/guard-missing.log" 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] || fail "guard accepted a missing -slim config"
grep -q 'slim variant config not found' "$TEST_DIR/guard-missing.log" || fail "missing guard config error"

popd >/dev/null

# --- Several versions under one repository, tag templates ----------------------------

versioned="$TEST_DIR/versioned.json"
cat > "$versioned" <<'JSON'
{
  "version": 2,
  "registry": "registry.example.invalid/images",
  "tag_template": "{version}-{date}-{sha12}",
  "ref_tag_template": "{version}",
  "images": {
    "geth-v1-16": {
      "repository": "group/geth",
      "version": "v1.16",
      "builders": {"docker": {"context": "geth/v1.16"}},
      "smoke": {"commands": ["geth version"]}
    },
    "geth-v1-17": {
      "repository": "group/geth",
      "version": "v1.17",
      "builders": {"apko": {"config": "geth/v1.17/apko.yaml"}},
      "smoke": {"commands": ["geth version"]}
    },
    "plain": {
      "builders": {"docker": {}},
      "tag_template": "{sha}",
      "ref_tag_template": "{ref}"
    }
  }
}
JSON
DATED_TAG='^(.+)-[0-9]{8}-[0-9a-f]{12}$'

run_plan versioned "$versioned" TRUSTED=true BUILD_DATE=20261127
versioned_pub=$(matrix publish_matrix)
assert_json "$versioned_pub" '[.[] | select(.image == "geth-v1-16") | .repository] | unique | join(",")' 'group/geth'
assert_json "$versioned_pub" '[.[] | select(.image == "geth-v1-16") | .sha_tag] | unique | join(",")' 'v1.16-20261127-0123456789ab'
assert_json "$versioned_pub" '[.[] | select(.image == "geth-v1-16") | .ref_tag] | unique | join(",")' 'v1.16'
assert_json "$versioned_pub" '[.[] | select(.image == "geth-v1-17") | .repository, .sha_tag, .ref_tag] | join(",")' 'group/geth,v1.17-20261127-0123456789ab,v1.17'
assert_json "$versioned_pub" '[.[] | select(.image == "plain") | .repository, .sha_tag, .ref_tag] | unique | join(",")' "$SHA,main,plain"
assert_json "$(matrix manifest_matrix)" '[.[] | .image + "=" + .repository + ":" + .sha_tag] | sort | join(",")' \
  "geth-v1-16=group/geth:v1.16-20261127-0123456789ab,plain=plain:$SHA"
assert_json "$(matrix smoke_matrix)" '[.[] | select(.image | startswith("geth")) | .repository] | unique | join(",")' 'group/geth'
assert_json "$versioned_pub" "[.[] | select(.image | startswith(\"geth\")) | (.sha_tag | test(\"$DATED_TAG\"))] | all" 'true'
assert_json "$versioned_pub" "[.[] | select(.image | startswith(\"geth\")) | (.sha_tag | capture(\"^(?<v>.+)-[0-9]{8}-[0-9a-f]{12}\$\").v)] | unique | join(\",\")" 'v1.16,v1.17'

run_plan versioned_today "$versioned" TRUSTED=true
today=$(date -u +%Y%m%d)
assert_json "$(matrix publish_matrix)" '[.[] | select(.image == "geth-v1-17") | .sha_tag] | join(",")' "v1.17-$today-0123456789ab"

run_plan versioned_untrusted "$versioned" GITHUB_EVENT_NAME=workflow_dispatch TRUSTED=false
assert_json "$(matrix build_matrix)" '[.[].local_ref] | sort | join(",")' 'local/geth-v1-16-docker:smoke,local/geth-v1-17-apko:smoke,local/plain-docker:smoke'

run_plan versioned_release "$versioned" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/plain/v2.0.0 \
  GITHUB_REF_NAME=plain/v2.0.0 GITHUB_REF_TYPE=tag TRUSTED=true BUILD_DATE=20261127
assert_json "$(matrix publish_matrix)" '[.[].ref_tag] | unique | join(",")' 'plain-v2.0.0'

run_plan default_templates "$v2" TRUSTED=true BUILD_DATE=20261127
assert_json "$(matrix publish_matrix)" '[.[] | .repository + ":" + .sha_tag] | unique | sort | join(",")' \
  "gadget:$SHA,gadget:$SHA-dev,widget:$SHA"

reject_versioned() {
  jq "$2" "$versioned" > "$TEST_DIR/$1.json"
  expect_plan_error "$1" "$TEST_DIR/$1.json" "$3" TRUSTED=true
}

reject_versioned shared_no_version 'del(.images["geth-v1-16"].version) | .images["geth-v1-16"].tag_template = "{sha}" | .images["geth-v1-16"].ref_tag_template = "{ref}"' 'so each must set version'
reject_versioned shared_same_version '.images["geth-v1-17"].version = "v1.16"' 'so their versions must differ'
reject_versioned shared_template '.images["geth-v1-17"].ref_tag_template = "{ref}"' 'must both contain {version}'
reject_versioned shared_aliases '.default_branch_tags = ["latest"]' 'cannot publish default_branch_tags'
reject_versioned template_no_sha '.images.plain.tag_template = "{ref}"' 'must contain {sha} or {sha12}'
reject_versioned template_unknown '.images.plain.tag_template = "{branch}-{sha}"' 'may only contain letters, digits, dot, dash, and the placeholders'
reject_versioned template_no_version '.images.plain.tag_template = "{version}-{sha}"' 'so the image must set version'
reject_versioned bad_repository '.images.plain.repository = "Group/Plain"' 'repository must be a lowercase registry path'
reject_versioned bad_version '.images.plain.version = "v1/2"' 'version may only contain'
expect_plan_error bad_build_date "$versioned" 'BUILD_DATE must be YYYYMMDD' TRUSTED=true BUILD_DATE=2026-11-27

# Lock files planned for fetch-apks.
lock_dir="$TEST_DIR/locks"
mkdir -p "$lock_dir/apko" "$lock_dir/melange"
pushd "$lock_dir" >/dev/null
echo '{}' > apko/gadget.lock.json
echo '{}' > apko/gadget-dev.lock.json
echo '{}' > melange/stack.lock.json

write_lock_catalog() {
  local registry="$1" gadget_lock="${2:-apko/gadget.lock.json}"
  cat > "$3" <<JSON
{
  "version": 2,
  "registry": "registry.example.invalid/images",
  ${registry}
  "packages": {
    "stack": {"config": "melange/stack.yaml", "archs": ["x86_64", "aarch64"], "env_lockfile": "melange/stack.lock.json"}
  },
  "images": {
    "gadget": {
      "builders": {
        "apko": {
          "configs": [
            {"config": "apko/gadget.yaml", "tag_suffix": "", "lockfile": "${gadget_lock}"},
            {"config": "apko/gadget-dev.yaml", "tag_suffix": "-dev", "lockfile": "apko/gadget-dev.lock.json"}
          ]
        }
      }
    },
    "plain": {
      "builders": {"apko": {"config": "apko/plain.yaml"}}
    }
  }
}
JSON
}

registry_block='"apk_registry": {"host": "apk.example.dev", "path_prefix": "/org/", "chainguard_identity": "abc/def", "redirect_hosts": ["*.storage.example.net"]},'
write_lock_catalog "$registry_block" apko/gadget.lock.json lock.json
run_plan lock_trusted lock.json TRUSTED=true
assert_eq "$(out_value "$OUT" has_apk_fetch)" "true" "has_apk_fetch on a lock catalog"
fetch=$(out_value "$OUT" apk_fetch)
assert_json "$fetch" '.lockfiles | join(",")' "apko/gadget-dev.lock.json,apko/gadget.lock.json,melange/stack.lock.json"
assert_json "$fetch" '.host' "apk.example.dev"
assert_json "$fetch" '.path_prefix' "/org/"
assert_json "$fetch" '.identity' "abc/def"
assert_json "$fetch" '.redirect_hosts | join(",")' "*.storage.example.net"
assert_json "$fetch" '.archs | length' "0"

assert_json "$(out_value "$OUT" publish_matrix)" '[.[] | select(.image == "gadget") | .lockfile] | join(",")' "apko/gadget.lock.json,apko/gadget-dev.lock.json"
assert_json "$(out_value "$OUT" publish_matrix)" '.[] | select(.image == "plain") | .lockfile' ""

run_plan lock_untrusted lock.json TRUSTED=false
assert_json "$(out_value "$OUT" apk_fetch)" '.archs | join(",")' "x86_64"
assert_json "$(out_value "$OUT" build_matrix)" '[.[] | select(.image == "gadget") | .lockfile] | join(",")' "apko/gadget.lock.json,apko/gadget-dev.lock.json"

write_lock_catalog '"apk_registry": {"host": "apk.example.dev", "path_prefix": "/org/"},' apko/gadget.lock.json anon.json
run_plan lock_anonymous anon.json TRUSTED=true
assert_json "$(out_value "$OUT" apk_fetch)" '.identity' ""
assert_json "$(out_value "$OUT" apk_fetch)" '.redirect_hosts | length' "0"

run_plan no_locks "$(write_v2_catalog "$TEST_DIR/no-locks.json"; echo "$TEST_DIR/no-locks.json")" TRUSTED=true
assert_eq "$(out_value "$OUT" has_apk_fetch)" "false" "has_apk_fetch without lock files"
assert_eq "$(out_value "$OUT" apk_fetch)" "{}" "apk_fetch without lock files"

write_lock_catalog "" apko/gadget.lock.json no-registry.json
expect_plan_error lock_without_registry no-registry.json "need an apk_registry block" TRUSTED=true
write_lock_catalog "$registry_block" apko/missing.lock.json missing.json
expect_plan_error lock_missing missing.json "lock file not found: apko/missing.lock.json" TRUSTED=true
write_lock_catalog "$registry_block" ../outside.lock.json traversal.json
expect_plan_error lock_traversal traversal.json "apko lockfile must be a relative path" TRUSTED=true
write_lock_catalog '"apk_registry": {"host": "https://apk.example.dev", "path_prefix": "/org/"},' apko/gadget.lock.json bad-host.json
expect_plan_error lock_bad_host bad-host.json "apk_registry.host must be a lowercase DNS name" TRUSTED=true
write_lock_catalog '"apk_registry": {"host": "apk.example.dev", "path_prefix": "org"},' apko/gadget.lock.json bad-prefix.json
expect_plan_error lock_bad_prefix bad-prefix.json "apk_registry.path_prefix must start and end with /" TRUSTED=true
write_lock_catalog '"apk_registry": {"host": "apk.example.dev", "path_prefix": "/org/", "redirect_hosts": ["*"]},' apko/gadget.lock.json bad-redirect.json
expect_plan_error lock_bad_redirect bad-redirect.json "apk_registry.redirect_hosts must be" TRUSTED=true
write_lock_catalog '"apk_registry": {"host": "apk.example.dev", "path_prefix": "/org/", "allow": true},' apko/gadget.lock.json unknown.json
expect_plan_error lock_unknown_field unknown.json "apk_registry: unknown field allow" TRUSTED=true
printf '%s' '{"version":2,"apk_registry":{"host":"apk.example.dev","path_prefix":"/org/"},"images":{"x":{"builders":{"apko":{"lockfile":"a.lock.json","configs":[{"config":"apko/x.yaml"}]}}}}}' > both.json
expect_plan_error lock_both_forms both.json "builders.apko.lockfile applies to the single config form" TRUSTED=true
printf '%s' '{"version":2,"apk_registry":{"host":"apk.example.dev","path_prefix":"/org/"},"packages":{"stack":{}},"images":{"x":{"builders":{"apko":{"lockfile":"apko/gadget.lock.json","needs_packages":["stack"]}}}}}' > local.json
expect_plan_error lock_with_local_packages local.json "an apko lockfile with needs_packages is not supported yet" TRUSTED=true

popd >/dev/null

echo "plan-images tests passed"
