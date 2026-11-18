#!/usr/bin/env bash
# Plan the packages, build, publish, manifest, and arm64 smoke matrices for
# .github/workflows/build-images.yaml.
#
# Usage: plan-images.sh <catalog.json>
#
# The catalog is a v2 images catalog (version: 2), or a legacy v1 images.json.
# A legacy catalog is merged in memory with the legacy apko catalog
# (LEGACY_APKO_CONFIG, default .github/images.apko.json) when that file exists.
#
# Environment:
#   TRUSTED             "true" or "false" from actions/fork-context (required)
#   LEGACY_APKO_CONFIG  legacy apko catalog path (optional)
#   GITHUB_OUTPUT       file that receives the outputs (required)
#   GITHUB_EVENT_NAME, GITHUB_EVENT_PATH, GITHUB_REF, GITHUB_REF_NAME,
#   GITHUB_REF_TYPE, GITHUB_SHA are provided by Actions.
set -euo pipefail

CONFIG="${1:?catalog path required}"
TRUSTED="${TRUSTED:-}"
case "$TRUSTED" in
  true|false) ;;
  *) echo "::error::TRUSTED must be true or false" >&2; exit 1 ;;
esac
if [[ ! -f "$CONFIG" ]]; then
  echo "::error::Catalog not found: $CONFIG" >&2
  exit 1
fi
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

LEGACY_APKO_CONFIG="${LEGACY_APKO_CONFIG:-.github/images.apko.json}"
EVENT_NAME="${GITHUB_EVENT_NAME:-workflow_dispatch}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"
REF_TYPE="${GITHUB_REF_TYPE:-}"
REF_NAME="${GITHUB_REF_NAME:-}"
HEAD_SHA="${GITHUB_SHA:-HEAD}"
if [[ -z "$REF_TYPE" && -n "${GITHUB_REF:-}" ]]; then
  if [[ "$GITHUB_REF" == refs/tags/* ]]; then
    REF_TYPE="tag"
    REF_NAME="${REF_NAME:-${GITHUB_REF#refs/tags/}}"
  elif [[ "$GITHUB_REF" == refs/heads/* ]]; then
    REF_TYPE="branch"
    REF_NAME="${REF_NAME:-${GITHUB_REF#refs/heads/}}"
  fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MODEL="$WORK/model.json"

# jq library shared by normalization and matrix generation.
read -r -d '' JQ_LIB <<'JQ' || true
def csv_arr:
  if . == null or . == "" then []
  else split(",") | map(gsub("^ +| +$"; "")) | map(select(length > 0))
  end;

def lines_arr:
  if . == null then []
  elif type == "array" then .
  elif . == "" then []
  else split("\n") | map(select(length > 0))
  end;

def kv_obj:
  if . == null then {}
  elif type == "object" then .
  else
    lines_arr
    | map(. as $l
        | (index("=")) as $ix
        | if $ix == null then error("expected KEY=VALUE: \($l)")
          else {(.[0:$ix]): .[$ix + 1:]} end)
    | add // {}
  end;

def apko_arch_name:
  if . == "x86_64" then "amd64" elif . == "aarch64" then "arm64" else . end;

def has_member($xs; $x): any($xs[]; . == $x);

def is_one_of($v; $xs): any($xs[]; . == $v);

def norm_package($k):
  (if . == null then {} else . end) as $c
  | {
      config: ($c.config // ("melange/" + $k + ".yaml")),
      runner_profile: (if ($c | has("runner_profile")) then $c.runner_profile else "standard" end),
      source: ($c.source // null),
      source_submodules: (($c.source_submodules // "false") | tostring),
      use_gha_cache: ($c.use_gha_cache // false),
      cache_key_files: ($c.cache_key_files // []),
      archs: ($c.archs // ["x86_64", "aarch64"]),
      cargo_profile: {
        trusted: ($c.cargo_profile.trusted // ""),
        untrusted: ($c.cargo_profile.untrusted // "")
      },
      build_env: ($c.build_env // ""),
      build_version: ($c.build_version // "")
    };

def validate_package($k):
  if is_one_of(.runner_profile; ["standard", "large"]) | not
    then error("packages.\($k).runner_profile must be standard or large") else . end
  | if ([.archs[] | select(is_one_of(.; ["x86_64", "aarch64"]) | not)] | length) > 0 or (.archs | length) == 0
    then error("packages.\($k).archs must be a non-empty subset of x86_64, aarch64") else . end
  | if .source != null and ((.source.path // ".") == ".")
    then error("packages.\($k).source.path must be a subdirectory, not '.', so the checkout does not clean the workspace") else . end;

def norm_builders($n; $b):
  if ($b | type) != "object" then error("image \($n): builders must be an object") else . end
  | ($b | keys - ["apko", "docker"]) as $unknown
  | if ($unknown | length) > 0 then error("image \($n): unknown builder \($unknown[0])") else . end
  | if ($b | length) == 0 then error("image \($n): at least one builder is required") else . end
  | {}
    + (if $b.docker then {docker: {
          mode: ($b.docker.mode // "build"),
          context: ($b.docker.context // "."),
          dockerfile: ($b.docker.dockerfile // "Dockerfile"),
          target: ($b.docker.target // ""),
          build_args: ($b.docker.build_args | kv_obj),
          bake_file: ($b.docker.bake_file // "docker-bake.hcl"),
          set: ($b.docker.set | lines_arr)
        }} else {} end)
    + (if $b.apko then {apko: {
          needs_packages: ($b.apko.needs_packages // []),
          configs: (if ($b.apko.configs // null) != null then
                      [$b.apko.configs[] | {config: .config, tag_suffix: (.tag_suffix // "")}]
                    else [{config: ($b.apko.config // ("apko/" + $n + ".yaml")), tag_suffix: ""}] end)
        }} else {} end);

def norm_image($n):
  if type != "object" then error("image \($n) must be an object") else . end
  | . as $i
  | {
      builders: norm_builders($n; $i.builders),
      archs: ($i.archs // ["amd64", "arm64"]),
      paths: ($i.paths // []),
      smoke: {
        commands: ($i.smoke.commands // []),
        script: ($i.smoke.script // ""),
        verify_version: ($i.smoke.verify_version // false)
      }
    }
  | .primary = (
      if ($i.primary // null) != null then $i.primary
      elif (.builders | has("docker")) and (.builders | has("apko")) then
        error("image \($n): primary is required when both docker and apko builders are set")
      else (.builders | keys)[0]
      end);

def validate_image($n; $pkgs):
  . as $i
  | if ($n | test("^[a-z0-9][a-z0-9._-]*$")) | not
      then error("image name \($n) must match ^[a-z0-9][a-z0-9._-]*$") else . end
  | if is_one_of($i.primary; ["docker", "apko"]) | not
      then error("image \($n): primary must be docker or apko") else . end
  | if (.builders | has($i.primary)) | not
      then error("image \($n): primary \($i.primary) has no matching builder") else . end
  | if ($i.archs | length) == 0 or ([$i.archs[] | select(is_one_of(.; ["amd64", "arm64"]) | not)] | length) > 0
      then error("image \($n): archs must be a non-empty subset of amd64, arm64") else . end
  | if .builders.docker != null then
      (if is_one_of(.builders.docker.mode; ["build", "bake"]) | not
         then error("image \($n): docker.mode must be build or bake") else . end)
      | (if .builders.docker.mode == "bake" and .builders.docker.bake_file == ""
           then error("image \($n): docker.bake_file is required for bake mode") else . end)
    else . end
  | if .builders.apko != null then
      (.builders.apko.configs as $cfgs
       | (if ($cfgs | length) == 0 then error("image \($n): apko needs at least one config") else . end)
       | (if ([$cfgs[].tag_suffix] | unique | length) != ($cfgs | length)
            then error("image \($n): apko config tag_suffix values must be unique") else . end)
       | (if any($cfgs[]; (.tag_suffix | test("^[a-zA-Z0-9.-]*$")) | not)
            then error("image \($n): tag_suffix may only contain letters, digits, dot, dash") else . end)
       | (if any(.builders.apko.needs_packages[]; is_one_of(.; $pkgs) | not)
            then error("image \($n): needs_packages must name entries in packages") else . end))
    else . end
  | if (.smoke.verify_version | type) != "boolean"
      then error("image \($n): smoke.verify_version must be boolean") else . end;

def normalize_v2:
  if (.version | tostring) != "2" then error("catalog version must be 2") else . end
  | if ((.registry // "") | type) != "string" then error("registry must be a string") else . end
  | if (((.tag_prefix // "") | tostring) | test("^[a-zA-Z0-9.-]*$")) | not
      then error("tag_prefix may only contain letters, digits, dot, dash") else . end
  | . as $c
  | (reduce (($c.packages // {}) | to_entries[]) as $e ({};
        .[$e.key] = ($e.value | norm_package($e.key) | validate_package($e.key)))) as $pkgs
  | ($pkgs | keys) as $pkgnames
  | {
      version: 2,
      registry: ($c.registry // ""),
      tag_prefix: ($c.tag_prefix // ""),
      release: ({
          tag_regex: "^([^/]+)/(v.+)$",
          service_match: 1,
          version_match: 2,
          service: "",
          publish_tag: "${version}",
          source_ref: "${ref_name}"
        } + ($c.release // {})),
      shared_paths: ($c.shared_paths // []),
      packages: $pkgs,
      hooks: {pre_build: ($c.hooks.pre_build // "")},
      images: (reduce (($c.images // {}) | to_entries[]) as $e ({};
          .[$e.key] = ($e.value | norm_image($e.key) | validate_image($e.key; $pkgnames))))
    }
  | if (.release.tag_regex | type) != "string" then error("release.tag_regex must be a string") else . end
  | if (.hooks.pre_build | type) != "string" then error("hooks.pre_build must be a string") else . end;

def legacy_to_v2($d; $a):
  if ($d | has("default_runners")) or ($a | has("default_runners"))
    then error("Remove default_runners and melange.<stack>.runners; use melange.<stack>.runner_profile (standard or large)") else . end
  | if ([($a.melange // {})[] | has("runners")] | any)
    then error("Remove default_runners and melange.<stack>.runners; use melange.<stack>.runner_profile (standard or large)") else . end
  | if ($d | has("apko_images")) or ($d | has("groups"))
    then error("images.json uses the unsupported apko_images or groups format; migrate it to a version 2 catalog") else . end
  | ($d.images // {}) as $di
  | ($a.images // {}) as $ai
  | (($di | keys) + ($ai | keys) | unique) as $names
  | ([$d.registry, $a.registry] + [($di[]? | .registry)] + [($ai[]? | .registry)]
      | map(select(. != null and . != "")) | .[0] // "") as $registry
  | ([($a.melange // {}) | keys[]] + [$ai[]? | (.needs_melange // [])[]] | unique) as $pkgnames
  | {
      version: 2,
      registry: $registry,
      tag_prefix: "",
      release: ($a.release // {}),
      shared_paths: (($d.shared_paths // []) + ($a.shared_paths // []) | unique),
      packages: (reduce $pkgnames[] as $k ({};
          .[$k] = ({archs: ($a.melange_archs // null)} + ($a.melange[$k] // {})))),
      hooks: {},
      images: (reduce $names[] as $n ({};
          ($di[$n] // null) as $d1
          | ($ai[$n] // null) as $a1
          | (($d1.type // $a1.type) // null) as $t
          | if ($d1 != null) and ((($d1.mode // "build") | IN("build", "bake")) | not)
              then error("image \($n): mode \($d1.mode) is not supported by build-images.yaml") else . end
          | if $d1 != null and ($d1 | has("env"))
              then error("image \($n): env is not supported by build-images.yaml") else . end
          | .[$n] = {
              builders: ({}
                + (if $d1 == null then {} else {docker: {
                    mode: ($d1.mode // "build"),
                    context: ($d1.context // "."),
                    dockerfile: ($d1.dockerfile // "Dockerfile"),
                    target: ($d1.target // ""),
                    build_args: ($d1.build_args | kv_obj),
                    bake_file: ($d1.bake_file // "docker-bake.hcl"),
                    set: ($d1.set | lines_arr)
                  }} end)
                + (if $a1 == null then {} else {apko: {
                    needs_packages: ($a1.needs_melange // []),
                    configs: [($a1.apko_configs // ["apko/" + $n + ".yaml"])[]
                      | {config: ., tag_suffix: (sub("^apko/"; "") | sub("\\.yaml$"; "") | ltrimstr($n))}]
                  }} end)),
              primary: (if $d1 != null then "docker" else "apko" end),
              archs: (if $a1 != null then (($a1.apko_archs // $a.apko_archs // "amd64,arm64") | csv_arr | map(apko_arch_name))
                      elif ($d1.skip_arm64 // false) then ["amd64"]
                      else ["amd64", "arm64"] end),
              paths: (($d1.paths // []) + ($a1.paths // []) + ($a1.nexus_paths // []) + ($a1.apko_configs // [])
                      + (if $t == null then [] else (($d["shared_" + $t + "_paths"] // []) + ($a["shared_" + $t + "_paths"] // [])) end)),
              smoke: {
                commands: (($a1.smoke_test // "") | csv_arr),
                script: "",
                verify_version: ($a1.verify_version // false)
              }
            }
        ))
    };

def runner_for($profile; $arch):
  if $profile == "standard" and $arch == "x86_64" then "ubuntu-24.04"
  elif $profile == "standard" and $arch == "aarch64" then "ubuntu-24.04-arm"
  elif $profile == "large" and $arch == "x86_64" then "oplabs-ubuntu-x86"
  elif $profile == "large" and $arch == "aarch64" then "oplabs-ubuntu-arm"
  else error("unsupported runner profile or architecture: \($profile) \($arch)") end;

def sanitize_ref: gsub("[^a-zA-Z0-9.]"; "-");
def sanitize_suffix: gsub("[^a-zA-Z0-9.-]"; "-");
def has_smoke($i): (($i.smoke.commands | length) > 0) or ($i.smoke.script != "");
def prefix_for($m; $i; $b): $m.tag_prefix + (if $i.primary == $b then "" else ($b + "-") end);
def local_ref($id): "local/" + ($id | ascii_downcase) + ":smoke";
def merge_args($hook; $args): ($hook + $args) | to_entries | map("\(.key)=\(.value)") | join("\n");
def pkg_env($hook; $env): [$hook, $env] | map(select(. != "")) | join("\n");
JQ

# Normalize the catalog into the version 2 model at $MODEL.
normalize_catalog() {
  local version
  version=$(jq -r 'if type == "object" then (.version // 1 | tostring)
                   else error("catalog must be a JSON object") end' "$CONFIG")
  case "$version" in
    2)
      jq -c "${JQ_LIB} normalize_v2" "$CONFIG" > "$MODEL"
      echo "Catalog: version 2 ($CONFIG)"
      ;;
    1)
      local apko_file="$WORK/no-apko.json"
      echo '{}' > "$apko_file"
      if [[ -f "$LEGACY_APKO_CONFIG" ]]; then
        apko_file="$LEGACY_APKO_CONFIG"
        echo "Catalog: legacy v1 $CONFIG merged with $LEGACY_APKO_CONFIG"
      else
        echo "Catalog: legacy v1 $CONFIG"
      fi
      jq -c --slurpfile a "$apko_file" "${JQ_LIB} legacy_to_v2(.; \$a[0]) | normalize_v2" "$CONFIG" > "$MODEL"
      ;;
    *)
      echo "::error::Unsupported catalog version: $version" >&2
      exit 1
      ;;
  esac
}

# Run the optional pre-build hook and return its KEY=VALUE pairs as a JSON object.
run_hook() {
  local hook_path hook_out
  hook_path=$(jq -r '.hooks.pre_build // ""' "$MODEL")
  if [[ -z "$hook_path" ]]; then
    echo '{}'
    return 0
  fi
  if [[ ! -f "$hook_path" ]]; then
    echo "::error::hooks.pre_build script not found: $hook_path" >&2
    exit 1
  fi
  hook_out="$WORK/hook.out"
  bash "$hook_path" > "$hook_out"
  jq -Rn '[inputs | select(length > 0)
           | (index("=")) as $ix
           | if $ix == null or $ix == 0 or ((.[0:$ix]) | test("^[A-Za-z_][A-Za-z0-9_]*$") | not)
               then error("hook output is not KEY=VALUE: \(.)")
             else {(.[0:$ix]): .[$ix + 1:]} end] | add // {}' < "$hook_out"
}

matches_pattern() {
  local file="$1" pattern="$2"
  if [[ "$pattern" == *"/**" ]]; then
    local prefix="${pattern%/**}"
    [[ "$file" == "$prefix/"* ]] && return 0
  else
    [[ "$file" == "$pattern" ]] && return 0
  fi
  return 1
}

any_changed_matches() {
  local pattern="$1" file
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if matches_pattern "$file" "$pattern"; then
      return 0
    fi
  done <<< "$CHANGED_FILES"
  return 1
}

pipelines_for_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 0
  grep -oE 'uses:[[:space:]]*[A-Za-z0-9_-]+/[A-Za-z0-9_-]+' "$cfg" \
    | awk '{print $2}' | cut -d/ -f1 | sort -u || true
}

# Compute CHANGED_FILES for pull_request, merge_group, and push events.
# Returns non-zero when no reliable base and head exist.
compute_changed_files() {
  local base="" head="$HEAD_SHA"
  if [[ -n "$EVENT_PATH" && -f "$EVENT_PATH" ]]; then
    case "$EVENT_NAME" in
      pull_request)
        base=$(jq -r '.pull_request.base.sha // empty' "$EVENT_PATH")
        head=$(jq -r '.pull_request.head.sha // empty' "$EVENT_PATH")
        ;;
      merge_group)
        base=$(jq -r '.merge_group.base_sha // empty' "$EVENT_PATH")
        ;;
      push)
        base=$(jq -r '.before // empty' "$EVENT_PATH")
        head=$(jq -r '.after // empty' "$EVENT_PATH")
        ;;
    esac
  fi
  if [[ -z "$base" || "$base" =~ ^0+$ || -z "$head" ]]; then
    return 1
  fi
  git fetch --no-tags origin "$base" "$head" >&2 || true
  if ! git rev-parse --verify "${base}^{commit}" >/dev/null 2>&1 \
     || ! git rev-parse --verify "${head}^{commit}" >/dev/null 2>&1; then
    return 1
  fi
  CHANGED_FILES=$(git diff --name-only "${base}...${head}" 2>/dev/null) || return 1
  return 0
}

ALL_IMAGES=()
ALL_PACKAGES=()
SELECT_IMAGES=()
SELECT_PACKAGES=()
CHANGED_FILES=""
IS_RELEASE=false
VERSION=""
PUBLISH_TAG="$REF_NAME"
SOURCE_REF_OVERRIDE=""

load_all() {
  mapfile -t ALL_IMAGES < <(jq -r '.images | keys[]' "$MODEL")
  mapfile -t ALL_PACKAGES < <(jq -r '.packages | keys[]' "$MODEL")
  SELECT_IMAGES=("${ALL_IMAGES[@]+"${ALL_IMAGES[@]}"}")
  SELECT_PACKAGES=("${ALL_PACKAGES[@]+"${ALL_PACKAGES[@]}"}")
}

plan_release() {
  IS_RELEASE=true
  local regex service_match version_match svc_template publish_template source_template
  regex=$(jq -r '.release.tag_regex' "$MODEL")
  service_match=$(jq -r '.release.service_match' "$MODEL")
  version_match=$(jq -r '.release.version_match' "$MODEL")
  if ! [[ "$service_match" =~ ^[0-9]+$ && "$version_match" =~ ^[0-9]+$ ]]; then
    echo "::error::release.service_match and release.version_match must be numeric capture indexes" >&2
    exit 1
  fi
  if [[ ! "$REF_NAME" =~ $regex ]]; then
    echo "Tag ref '$REF_NAME' does not match release.tag_regex; no builds"
    SELECT_IMAGES=()
    SELECT_PACKAGES=()
    return 0
  fi
  if (( service_match >= ${#BASH_REMATCH[@]} || version_match >= ${#BASH_REMATCH[@]} )); then
    echo "::error::release.tag_regex did not provide capture indexes for '$REF_NAME'" >&2
    exit 1
  fi
  local svc="${BASH_REMATCH[$service_match]}"
  local ver="${BASH_REMATCH[$version_match]}"
  render() {
    local v="$1"
    v="${v//\$\{service\}/$svc}"
    v="${v//\$\{version\}/$ver}"
    v="${v//\$\{ref_name\}/$REF_NAME}"
    printf '%s' "$v"
  }
  svc_template=$(jq -r '.release.service // ""' "$MODEL")
  if [[ -n "$svc_template" ]]; then
    svc=$(render "$svc_template")
  fi
  if ! jq -e --arg n "$svc" '.images[$n]' "$MODEL" >/dev/null 2>&1; then
    echo "Tag ref '$REF_NAME' resolved to '$svc', which is not in the catalog; no builds"
    SELECT_IMAGES=()
    SELECT_PACKAGES=()
    return 0
  fi
  VERSION="$ver"
  publish_template=$(jq -r '.release.publish_tag' "$MODEL")
  source_template=$(jq -r '.release.source_ref' "$MODEL")
  PUBLISH_TAG=$(render "$publish_template")
  SOURCE_REF_OVERRIDE=$(render "$source_template")
  echo "Release tag resolved: image=$svc version=$ver publish_tag=$PUBLISH_TAG source_ref=${SOURCE_REF_OVERRIDE:-<catalog default>}"
  SELECT_IMAGES=("$svc")
  SELECT_PACKAGES=()
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] && SELECT_PACKAGES+=("$p")
  done < <(jq -r --arg n "$svc" '.images[$n].builders.apko.needs_packages[]?' "$MODEL")
}

plan_changed() {
  local cfg_rel="${CONFIG#./}"
  local pattern file n p cfg pipe

  if any_changed_matches "$cfg_rel"; then
    echo "Catalog changed: planning the full catalog"
    load_all
    return 0
  fi
  if [[ -f "$LEGACY_APKO_CONFIG" ]] && any_changed_matches "${LEGACY_APKO_CONFIG#./}"; then
    echo "Legacy apko catalog changed: planning the full catalog"
    load_all
    return 0
  fi
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    if any_changed_matches "$pattern"; then
      echo "Shared path matched $pattern: planning the full catalog"
      load_all
      return 0
    fi
  done < <(jq -r '.shared_paths[]?' "$MODEL")

  SELECT_IMAGES=()
  for n in "${ALL_IMAGES[@]+"${ALL_IMAGES[@]}"}"; do
    while IFS= read -r pattern; do
      [[ -z "$pattern" ]] && continue
      if any_changed_matches "$pattern"; then
        echo "Image path match: $pattern -> $n"
        SELECT_IMAGES+=("$n")
        break
      fi
    done < <(jq -r --arg n "$n" '.images[$n].paths[]?' "$MODEL")
  done

  local changed_pkgs=()
  for p in "${ALL_PACKAGES[@]+"${ALL_PACKAGES[@]}"}"; do
    cfg=$(jq -r --arg p "$p" '.packages[$p].config' "$MODEL")
    if any_changed_matches "$cfg"; then
      echo "Package config changed: $cfg -> $p"
      changed_pkgs+=("$p")
      continue
    fi
    while IFS= read -r pipe; do
      [[ -z "$pipe" ]] && continue
      if any_changed_matches "pipelines/${pipe}/**"; then
        echo "Pipeline $pipe changed -> package $p"
        changed_pkgs+=("$p")
        break
      fi
    done < <(pipelines_for_config "$cfg")
  done

  for n in "${ALL_IMAGES[@]+"${ALL_IMAGES[@]}"}"; do
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      for c in "${changed_pkgs[@]+"${changed_pkgs[@]}"}"; do
        if [[ "$c" == "$p" ]]; then
          SELECT_IMAGES+=("$n")
        fi
      done
    done < <(jq -r --arg n "$n" '.images[$n].builders.apko.needs_packages[]?' "$MODEL")
  done

  mapfile -t SELECT_IMAGES < <(printf '%s\n' "${SELECT_IMAGES[@]+"${SELECT_IMAGES[@]}"}" | sed '/^$/d' | sort -u)
  SELECT_PACKAGES=()
  for p in "${changed_pkgs[@]+"${changed_pkgs[@]}"}"; do
    SELECT_PACKAGES+=("$p")
  done
  for n in "${SELECT_IMAGES[@]+"${SELECT_IMAGES[@]}"}"; do
    while IFS= read -r p; do
      [[ -n "$p" ]] && SELECT_PACKAGES+=("$p")
    done < <(jq -r --arg n "$n" '.images[$n].builders.apko.needs_packages[]?' "$MODEL")
  done
  mapfile -t SELECT_PACKAGES < <(printf '%s\n' "${SELECT_PACKAGES[@]+"${SELECT_PACKAGES[@]}"}" | sed '/^$/d' | sort -u)
}

to_json_array() {
  printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length > 0)) | unique'
}

main() {
  normalize_catalog
  local hook_kv
  hook_kv=$(run_hook)

  if [[ "$REF_TYPE" == "tag" ]]; then
    plan_release
  elif [[ "$EVENT_NAME" == "pull_request" || "$EVENT_NAME" == "push" || "$EVENT_NAME" == "merge_group" ]]; then
    load_all
    if compute_changed_files; then
      echo "Changed files: $(printf '%s\n' "$CHANGED_FILES" | sed '/^$/d' | wc -l | tr -d ' ') ($EVENT_NAME)"
      printf '%s\n' "$CHANGED_FILES" | sed '/^$/d' | head -50
      if [[ -z "$(printf '%s' "$CHANGED_FILES" | sed '/^$/d')" ]]; then
        echo "No changed files: no builds"
        SELECT_IMAGES=()
        SELECT_PACKAGES=()
      else
        plan_changed
      fi
    else
      echo "::warning::Could not compute the changed files for $EVENT_NAME; planning the full catalog"
      load_all
    fi
  else
    echo "Event $EVENT_NAME: planning the full catalog"
    load_all
  fi

  local images_json packages_json
  images_json=$(to_json_array "${SELECT_IMAGES[@]+"${SELECT_IMAGES[@]}"}")
  packages_json=$(to_json_array "${SELECT_PACKAGES[@]+"${SELECT_PACKAGES[@]}"}")

  local registry
  registry=$(jq -r '.registry' "$MODEL")

  local outputs
  outputs=$(jq -c -n \
    --slurpfile m "$MODEL" \
    --argjson images "$images_json" \
    --argjson pkgs "$packages_json" \
    --argjson trusted "$TRUSTED" \
    --argjson hook "$hook_kv" \
    --arg sha "$HEAD_SHA" \
    --arg ref_name "$PUBLISH_TAG" \
    --arg version "$VERSION" \
    --arg source_ref_override "$SOURCE_REF_OVERRIDE" \
    --arg is_release "$IS_RELEASE" \
    "${JQ_LIB}"'
      $m[0] as $m
      | ($trusted) as $trusted
      | ([ $pkgs[] as $p
          | $m.packages[$p] as $c
          | (if $trusted then $c.archs else [$c.archs[] | select(. == "x86_64")] end)[] as $arch
          | {
              id: "\($p)-\($arch)",
              package: $p,
              arch: $arch,
              runner: runner_for($c.runner_profile; $arch),
              config: $c.config,
              checkout_source: ($c.source != null),
              source_repository: ($c.source.repository // ""),
              source_ref: (if $source_ref_override != "" and $c.source != null then $source_ref_override else ($c.source.ref // "") end),
              source_path: ($c.source.path // "."),
              source_submodules: $c.source_submodules,
              use_gha_cache: $c.use_gha_cache,
              cache_key_files: ($c.cache_key_files | join(",")),
              cargo_profile: (if $trusted then $c.cargo_profile.trusted else $c.cargo_profile.untrusted end),
              build_env: pkg_env(merge_args($hook; {}); $c.build_env),
              build_version: (if $version != "" then $version else $c.build_version end)
            }
        ]) as $packages
      | ([ if $trusted then empty else
            $images[] as $n
            | $m.images[$n] as $i
            | select(has_member($i.archs; "amd64"))
            | ( (if $i.builders.docker then [{
                    id: "\($n)-docker",
                    image: $n,
                    builder: "docker",
                    arch: "amd64",
                    runner: "ubuntu-24.04",
                    local_ref: local_ref("\($n)-docker"),
                    mode: $i.builders.docker.mode,
                    context: $i.builders.docker.context,
                    dockerfile: $i.builders.docker.dockerfile,
                    target: $i.builders.docker.target,
                    bake_file: $i.builders.docker.bake_file,
                    build_args: merge_args($hook; $i.builders.docker.build_args),
                    set: ($i.builders.docker.set | join("\n")),
                    config: "",
                    needs_packages: "",
                    suffix: "",
                    has_smoke: has_smoke($i),
                    smoke_commands: ($i.smoke.commands | tojson),
                    smoke_script: $i.smoke.script
                  }] else [] end)
              + (if $i.builders.apko then [ $i.builders.apko.configs[] as $v
                  | ($v.tag_suffix | sanitize_suffix) as $sfx
                  | {
                      id: "\($n)-apko\($sfx)",
                      image: $n,
                      builder: "apko",
                      arch: "amd64",
                      runner: "ubuntu-24.04",
                      local_ref: local_ref("\($n)-apko\($sfx)"),
                      mode: "",
                      context: "",
                      dockerfile: "",
                      target: "",
                      bake_file: "",
                      build_args: "",
                      set: "",
                      config: $v.config,
                      needs_packages: ($i.builders.apko.needs_packages | join(",")),
                      suffix: $v.tag_suffix,
                      has_smoke: ($v.tag_suffix == "" and has_smoke($i)),
                      smoke_commands: (if $v.tag_suffix == "" then ($i.smoke.commands | tojson) else "[]" end),
                      smoke_script: (if $v.tag_suffix == "" then $i.smoke.script else "" end)
                    }
                ] else [] end)
            ) | .[]
          end
        ]) as $build
      | ([ if $trusted | not then empty else
            $images[] as $n
            | $m.images[$n] as $i
            | $i.archs as $archs
            | ( (if $i.builders.docker then [ $archs[] as $a | {
                    id: "\($n)-docker-\($a)",
                    image: $n,
                    builder: "docker",
                    kind: "docker-arch",
                    arch: $a,
                    runner: (if $a == "amd64" then "ubuntu-24.04" else "ubuntu-24.04-arm" end),
                    local_ref: local_ref("\($n)-docker-\($a)"),
                    mode: $i.builders.docker.mode,
                    context: $i.builders.docker.context,
                    dockerfile: $i.builders.docker.dockerfile,
                    target: $i.builders.docker.target,
                    bake_file: $i.builders.docker.bake_file,
                    build_args: merge_args($hook; $i.builders.docker.build_args),
                    set: ($i.builders.docker.set | join("\n")),
                    config: "",
                    needs_packages: "",
                    suffix: "",
                    smoke_local: ($a == "amd64" and has_smoke($i)),
                    has_smoke: has_smoke($i),
                    smoke_commands: ($i.smoke.commands | tojson),
                    smoke_script: $i.smoke.script,
                    expected_version: (if $i.smoke.verify_version and $version != "" then $version else "" end),
                    sha_tag: (prefix_for($m; $i; "docker") + $sha),
                    ref_tag: (prefix_for($m; $i; "docker") + ($ref_name | sanitize_ref)),
                    registry: $m.registry
                  }] else [] end)
              + (if $i.builders.apko then [ $i.builders.apko.configs[] as $v
                  | ($v.tag_suffix | sanitize_suffix) as $sfx
                  | {
                      id: "\($n)-apko\($sfx)",
                      image: $n,
                      builder: "apko",
                      kind: "apko",
                      arch: "",
                      archs: ($archs | join(",")),
                      runner: "ubuntu-24.04",
                      local_ref: local_ref("\($n)-apko\($sfx)"),
                      mode: "",
                      context: "",
                      dockerfile: "",
                      target: "",
                      bake_file: "",
                      build_args: "",
                      set: "",
                      config: $v.config,
                      needs_packages: ($i.builders.apko.needs_packages | join(",")),
                      suffix: $v.tag_suffix,
                      smoke_local: ($v.tag_suffix == "" and has_member($archs; "amd64") and has_smoke($i)),
                      has_smoke: ($v.tag_suffix == "" and has_smoke($i)),
                      smoke_commands: (if $v.tag_suffix == "" then ($i.smoke.commands | tojson) else "[]" end),
                      smoke_script: (if $v.tag_suffix == "" then $i.smoke.script else "" end),
                      expected_version: (if $i.smoke.verify_version and $version != "" and $v.tag_suffix == "" then $version else "" end),
                      sha_tag: (prefix_for($m; $i; "apko") + $sha + $v.tag_suffix),
                      ref_tag: (prefix_for($m; $i; "apko") + ($ref_name | sanitize_ref) + $v.tag_suffix),
                      registry: $m.registry
                    }
                ] else [] end)
            ) | .[]
          end
        ]) as $publish
      | ([ if $trusted | not then empty else
            $images[] as $n
            | $m.images[$n] as $i
            | select($i.builders.docker != null and ($i.archs | length) > 0)
            | {
                id: "\($n)-docker",
                image: $n,
                registry: $m.registry,
                sha_tag: (prefix_for($m; $i; "docker") + $sha),
                ref_tag: (prefix_for($m; $i; "docker") + ($ref_name | sanitize_ref)),
                pushed_pattern: "pushed-\($n)-docker-*",
                final_artifact: "final-\($n)-docker"
              }
          end
        ]) as $manifest
      | ([ if $trusted | not then empty else
            $images[] as $n
            | $m.images[$n] as $i
            | select(has_smoke($i) and has_member($i.archs; "arm64"))
            | ( (if $i.builders.docker then [{
                    id: "\($n)-docker-arm64",
                    image: $n,
                    builder: "docker",
                    registry: $m.registry,
                    final_artifact: "final-\($n)-docker",
                    runner: "ubuntu-24.04-arm",
                    smoke_commands: ($i.smoke.commands | tojson),
                    smoke_script: $i.smoke.script,
                    expected_version: (if $i.smoke.verify_version and $version != "" then $version else "" end)
                  }] else [] end)
                + (if $i.builders.apko then [ $i.builders.apko.configs[] | select(.tag_suffix == "")
                    | {
                        id: "\($n)-apko-arm64",
                        image: $n,
                        builder: "apko",
                        registry: $m.registry,
                        final_artifact: "final-\($n)-apko",
                        runner: "ubuntu-24.04-arm",
                        smoke_commands: ($i.smoke.commands | tojson),
                        smoke_script: $i.smoke.script,
                        expected_version: (if $i.smoke.verify_version and $version != "" then $version else "" end)
                      }
                  ] else [] end)
              ) | .[]
          end
        ]) as $smoke
      | {
          trusted: ($trusted | tostring),
          is_release: $is_release,
          has_packages: (($packages | length) > 0 | tostring),
          has_builds: (($build | length) > 0 | tostring),
          has_publish: (($publish | length) > 0 | tostring),
          has_manifest: (($manifest | length) > 0 | tostring),
          has_smoke_arm64: (($smoke | length) > 0 | tostring),
          packages_matrix: ($packages | tojson),
          build_matrix: ($build | tojson),
          publish_matrix: ($publish | tojson),
          manifest_matrix: ($manifest | tojson),
          smoke_arm64_matrix: ($smoke | tojson),
          selected_images: ($images | join(",")),
          selected_packages: ($pkgs | join(","))
        }
    ')

  if [[ "$TRUSTED" == "true" ]] && [[ -z "$registry" ]]; then
    if [[ "$(jq -r '.publish_matrix' <<< "$outputs")" != "[]" || "$(jq -r '.manifest_matrix' <<< "$outputs")" != "[]" ]]; then
      echo "::error::A trusted run needs registry in the catalog to publish" >&2
      exit 1
    fi
  fi

  jq -r 'to_entries[] | "\(.key)=\(.value)"' <<< "$outputs" >> "$GITHUB_OUTPUT"
  jq -r '"selected images: \(.selected_images)\nselected packages: \(.selected_packages)\nbuild legs: \(.build_matrix | fromjson | length)\npackage legs: \(.packages_matrix | fromjson | length)\npublish legs: \(.publish_matrix | fromjson | length)\nmanifest legs: \(.manifest_matrix | fromjson | length)\narm64 smoke legs: \(.smoke_arm64_matrix | fromjson | length)"' <<< "$outputs"
}

main
