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
LEGACY_APKO_CONFIG="${LEGACY_APKO_CONFIG:-.github/images.apko.json}"
if [[ ! -f "$CONFIG" && ! -f "$LEGACY_APKO_CONFIG" ]]; then
  echo "::error::Catalog not found: $CONFIG" >&2
  exit 1
fi
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

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

def build_events: ["pull_request", "push", "schedule", "release", "workflow_dispatch"];

def apko_arch_name:
  if . == "x86_64" then "amd64" elif . == "aarch64" then "arm64" else . end;

def has_member($xs; $x): any($xs[]; . == $x);

def is_one_of($v; $xs): any($xs[]; . == $v);

def is_root_path: . == "" or . == "." or . == "./";

def norm_source($k; $s; $self):
  if $s == null then null
  elif $self then
    (if ($s | has("root")) then error("packages.\($k).source.root does not apply to the calling repository checkout") else null end)
  else
    ($s.path // ".") as $p
    | (if ($s | has("root")) then $s.root else ($p | is_root_path) end) as $root
    | if ($root | type) != "boolean" then error("packages.\($k).source.root must be true or false")
      elif ($p | is_root_path) and $root != true then error("packages.\($k).source.path '.' needs source.root: true, since a checkout at the workspace root would delete the caller's files")
      else $s + {path: (if $root and ($p | is_root_path) then ".package-sources/\($k)" else $p end), root: $root}
      end
  end;

def norm_package($k):
  (if . == null then {} else . end) as $c
  | ($c.source // null) as $s
  | ($ENV.GITHUB_REPOSITORY // "") as $caller
  | (if $s != null and $caller != "" and ((($s.repository // "") == "") or ($s.repository == $caller))
        and (($s.path // ".") == ".") and (($s.ref // "") == "")
     then true else false end) as $self
  | {
      config: ($c.config // ("melange/" + $k + ".yaml")),
      runner_profile: (if ($c | has("runner_profile")) then $c.runner_profile else "standard" end),
      source: norm_source($k; $s; $self),
      source_submodules: (if $self then "false" else (($c.source_submodules // "false") | tostring) end),
      submodules: ((if $self then ($c.submodules // $c.source_submodules) else $c.submodules end) // "false" | tostring),
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
  if ($k | test("^[a-z0-9][a-z0-9._-]*$")) | not
    then error("package name \($k) must match ^[a-z0-9][a-z0-9._-]*$") else . end
  | if is_one_of(.runner_profile; ["standard", "large"]) | not
    then error("packages.\($k).runner_profile must be standard or large") else . end
  | if ([.archs[] | select(is_one_of(.; ["x86_64", "aarch64"]) | not)] | length) > 0 or (.archs | length) == 0
    then error("packages.\($k).archs must be a non-empty subset of x86_64, aarch64") else . end
  | if is_one_of(.submodules; ["false", "true", "recursive"]) | not
    then error("packages.\($k).submodules must be false, true, or recursive") else . end
  | if .submodules != "false" and .source != null
    then error("packages.\($k).submodules applies only to the calling repository checkout; use source_submodules for a source") else . end;

def norm_builders($n; $b):
  if ($b | type) != "object" then error("image \($n): builders must be an object") else . end
  | ($b | keys - ["apko", "docker"]) as $unknown
  | if ($unknown | length) > 0 then error("image \($n): unknown builder \($unknown[0])") else . end
  | if ($b | length) == 0 then error("image \($n): at least one builder is required") else . end
  | if ($b.docker | type) == "object" and ($b.docker | has("git_build_args")) and (($b.docker.git_build_args | type) != "boolean")
      then error("image \($n): builders.docker.git_build_args must be a boolean") else . end
  | if ($b.docker | type) == "object" and ($b.docker.git_build_args == true) and (($b.docker.mode // "build") == "bake")
      then error("image \($n): git_build_args is not supported for mode bake") else . end
  | {}
    + (if $b.docker then {docker: {
          mode: ($b.docker.mode // "build"),
          context: ($b.docker.context // "."),
          dockerfile: ($b.docker.dockerfile // "Dockerfile"),
          target: ($b.docker.target // ""),
          build_args: ($b.docker.build_args | kv_obj),
          git_build_args: ($b.docker.git_build_args // false),
          bake_file: ($b.docker.bake_file // "docker-bake.hcl"),
          set: ($b.docker.set | lines_arr),
          importpath: ($b.docker.importpath // "./cmd"),
          ko_config: ($b.docker.ko_config // ""),
          go_version_file: ($b.docker.go_version_file // ""),
          ldflags: ($b.docker.ldflags // []),
          env: ($b.docker.env // []),
          tag_prefix: ($b.docker.tag_prefix // null),
          archs: ($b.docker.archs // null),
          runner_profile: (if ($b.docker | has("runner_profile")) then $b.docker.runner_profile else "standard" end),
          events: (if ($b.docker | has("events")) then $b.docker.events else build_events end)
        }} else {} end)
    + (if $b.apko then {apko: {
          needs_packages: ($b.apko.needs_packages // []),
          tag_prefix: ($b.apko.tag_prefix // null),
          configs: (if ($b.apko.configs // null) != null then
                      [$b.apko.configs[] | {config: .config, tag_suffix: (.tag_suffix // ""), smoke: (.smoke // null), allow_packages: ((.allow_packages // []) | map(sub("[=<>~!].*$"; "")))}]
                    else [{config: ($b.apko.config // ("apko/" + $n + ".yaml")), tag_suffix: "", smoke: null, allow_packages: []}] end),
          archs: ($b.apko.archs // null),
          runner_profile: (if ($b.apko | has("runner_profile")) then $b.apko.runner_profile else "standard" end),
          events: (if ($b.apko | has("events")) then $b.apko.events else build_events end)
        }} else {} end);

def norm_smoke($s):
  if ($s | type) != "object" and ($s | type) != "null" then error("smoke must be an object") else null end
  | {
      commands: ($s.commands // []),
      script: ($s.script // ""),
      verify_version: ($s.verify_version // false)
    };

def norm_image($n):
  if type != "object" then error("image \($n) must be an object") else . end
  | . as $i
  | ($i.archs // ["amd64", "arm64"]) as $iarchs
  | norm_smoke($i.smoke) as $ismoke
  | (norm_builders($n; $i.builders)
      | with_entries(.value.archs = (.value.archs // $iarchs)
          | .value.smoke = (if $i.builders[.key].smoke == null then $ismoke else norm_smoke($i.builders[.key].smoke) end))
      | if .apko then ((.apko.smoke) as $asmoke
          | .apko.configs |= map(.smoke = (if .smoke == null then $asmoke else norm_smoke(.smoke) end)))
        else . end) as $builders
  | {
      builders: $builders,
      archs: $iarchs,
      paths: (($i.paths // []) + [(($builders.apko.configs // [])[].config)]),
      smoke: $ismoke
    }
  | .primary = (
      if ($i.primary // null) != null then $i.primary
      elif (.builders | has("docker")) and (.builders | has("apko")) then
        error("image \($n): primary is required when both docker and apko builders are set")
      else (.builders | keys)[0]
      end);

def tag_list($what):
  if type != "array" then error("\($what) must be an array of tag names") else . end
  | if any(.[]; (type != "string") or (test("^[a-zA-Z0-9.-]+$") | not))
      then error("\($what) entries must be non-empty and contain only letters, digits, dot, dash") else . end
  | reduce .[] as $t ([]; if any(.[]; . == $t) then . else . + [$t] end);

def validate_image($n; $pkgs):
  . as $i
  | if ($n | test("^[a-z0-9][a-z0-9._-]*$")) | not
      then error("image name \($n) must match ^[a-z0-9][a-z0-9._-]*$") else . end
  | if is_one_of($i.primary; ["docker", "apko"]) | not
      then error("image \($n): primary must be docker or apko") else . end
  | if (.builders | has($i.primary)) | not
      then error("image \($n): primary \($i.primary) has no matching builder") else . end
  | if ([(.builders | to_entries[]) | (.value.tag_prefix // "") | select(test("^[a-zA-Z0-9.-]*$") | not)] | length) > 0
      then error("image \($n): builders tag_prefix may only contain letters, digits, dot, dash") else . end
  | ([(.builders | to_entries[]) | select(is_one_of(.value.runner_profile; ["standard", "large"]) | not) | .key]) as $bad_runner
  | if ($bad_runner | length) > 0
      then error("image \($n): builders.\($bad_runner[0]).runner_profile must be standard or large") else . end
  | ([(.builders | to_entries[])
      | select((.value.events | type) != "array" or (.value.events | length) == 0 or any(.value.events[]; is_one_of(.; build_events) | not))
      | .key]) as $bad_events
  | if ($bad_events | length) > 0
      then error("image \($n): builders.\($bad_events[0]).events must be a non-empty array of pull_request, push, schedule, release, workflow_dispatch") else . end
  | if ($i.archs | length) == 0 or ([$i.archs[] | select(is_one_of(.; ["amd64", "arm64"]) | not)] | length) > 0
      then error("image \($n): archs must be a non-empty subset of amd64, arm64") else . end
  | ([(.builders | to_entries[])
      | select((.value.archs | length) == 0 or ([.value.archs[] | select(is_one_of(.; ["amd64", "arm64"]) | not)] | length) > 0)
      | .key]) as $bad_builders
  | if ($bad_builders | length) > 0
      then error("image \($n): builders.\($bad_builders[0]).archs must be a non-empty subset of amd64, arm64") else . end
  | ([(.builders | to_entries[]) | select((.value.smoke.verify_version | type) != "boolean") | .key]) as $bad_smoke
  | if ($bad_smoke | length) > 0
      then error("image \($n): builders.\($bad_smoke[0]).smoke.verify_version must be boolean") else . end
  | if .builders.docker != null then
      (if is_one_of(.builders.docker.mode; ["build", "bake", "ko"]) | not
         then error("image \($n): docker.mode must be build, bake, or ko") else . end)
      | (if .builders.docker.mode == "bake" and .builders.docker.bake_file == ""
           then error("image \($n): docker.bake_file is required for bake mode") else . end)
      | (if .builders.docker.mode == "ko" and .builders.docker.importpath == ""
           then error("image \($n): docker.importpath is required for ko mode") else . end)
      | (if any(.builders.docker.env[]; test("^[A-Za-z_][A-Za-z0-9_]*=") | not)
           then error("image \($n): docker.env entries must be KEY=VALUE") else . end)
    else . end
  | if .builders.apko != null then
      (.builders.apko.configs as $cfgs
       | (if ($cfgs | length) == 0 then error("image \($n): apko needs at least one config") else . end)
       | (if ([$cfgs[].tag_suffix] | unique | length) != ($cfgs | length)
            then error("image \($n): apko config tag_suffix values must be unique") else . end)
       | (if any($cfgs[]; (.tag_suffix | test("^[a-zA-Z0-9.-]*$")) | not)
            then error("image \($n): tag_suffix may only contain letters, digits, dot, dash") else . end)
       | (if any($cfgs[]; (.smoke.verify_version | type) != "boolean")
            then error("image \($n): apko config smoke.verify_version must be boolean") else . end)
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
  | (if $c | has("default_branch_tags") then ($c.default_branch_tags | tag_list("default_branch_tags")) else [] end) as $top_tags
  | (reduce (($c.packages // {}) | to_entries[]) as $e ({};
        .[$e.key] = ($e.value | norm_package($e.key) | validate_package($e.key)))) as $pkgs
  | ($pkgs | keys) as $pkgnames
  | {
      version: 2,
      registry: ($c.registry // ""),
      tag_prefix: ($c.tag_prefix // ""),
      default_branch_tags: $top_tags,
      release: ({
          tag_regex: "^([^/]+)/(v.+)$",
          service_match: 1,
          version_match: 2,
          service: "",
          publish_tag: "${ref_name}",
          source_ref: "${ref_name}"
        } + ($c.release // {})),
      shared_paths: ($c.shared_paths // []),
      packages: $pkgs,
      hooks: {pre_build: ($c.hooks.pre_build // "")},
      images: (reduce (($c.images // {}) | to_entries[]) as $e ({};
          .[$e.key] = ($e.value | norm_image($e.key) | validate_image($e.key; $pkgnames)
            | . + {default_branch_tags: (if ($e.value | has("default_branch_tags"))
                then ($e.value.default_branch_tags | tag_list("images.\($e.key).default_branch_tags"))
                else $top_tags end)})))
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
          | if ($d1 != null) and ((($d1.mode // "build") | IN("build", "bake", "ko")) | not)
              then error("image \($n): mode \($d1.mode) is not supported by build-images.yaml") else . end
          | if $d1 != null and ($d1 | has("env")) and (($d1.mode // "build") != "ko")
              then error("image \($n): env is only supported for mode ko by build-images.yaml") else . end
          | .[$n] = {
              builders: ({}
                + (if $d1 == null then {} else {docker: ({
                    mode: ($d1.mode // "build"),
                    context: ($d1.context // "."),
                    dockerfile: ($d1.dockerfile // "Dockerfile"),
                    target: ($d1.target // ""),
                    build_args: ($d1.build_args | kv_obj),
                    bake_file: ($d1.bake_file // "docker-bake.hcl"),
                    set: ($d1.set | lines_arr),
                    importpath: "./cmd",
                    ko_config: "",
                    go_version_file: "",
                    ldflags: [],
                    env: []
                  } + (if ($d1.mode // "build") == "ko" then {
                    context: ($d1.ko_working_directory // "."),
                    importpath: ($d1.ko_importpath // "./cmd"),
                    ko_config: ".ko.yaml",
                    go_version_file: ($d1.ko_go_version_file // ""),
                    env: ($d1.env | lines_arr)
                  } else {} end))} end)
                + (if $a1 == null then {} else {apko: {
                    needs_packages: ($a1.needs_melange // []),
                    tag_prefix: (if ($d.images // {} | length) > 0 then "apko-" else "" end),
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

def builder_runner($b; $arch):
  runner_for($b.runner_profile; if $arch == "amd64" then "x86_64" else "aarch64" end);

def sanitize_ref: gsub("[^a-zA-Z0-9.]"; "-");
def sanitize_suffix: gsub("[^a-zA-Z0-9.-]"; "-");
def has_smoke($s): (($s.commands | length) > 0) or ($s.script != "");
def uniq_keep: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
def prefix_for($m; $i; $b): $m.tag_prefix + ($i.builders[$b].tag_prefix // (if $i.primary == $b then "" else ($b + "-") end));
def local_ref($id): "local/" + ($id | ascii_downcase) + ":smoke";
def merge_args($hook; $args): ($hook + $args) | to_entries | map("\(.key)=\(.value)") | join("\n");
def pkg_env($hook; $env): [$hook, $env] | map(select(. != "")) | join("\n");
def release_env($env; $ver):
  if $ver == "" then $env
  else [$env[] | select(startswith("VERSION=") | not)] + ["VERSION=" + $ver]
  end;
def version_build_arg($d; $ver):
  if $d.mode == "build" and $ver != "" then $d.build_args + {VERSION: $ver}
  else $d.build_args
  end;
def git_build_args($d; $sha; $date): if $d.git_build_args == true then {GIT_COMMIT: $sha, GIT_DATE: $date} else {} end;
def git_env($env; $d; $sha; $date): if $d.git_build_args == true
  then [$env[] | select((startswith("GIT_COMMIT=") or startswith("GIT_DATE=")) | not)] + ["GIT_COMMIT=" + $sha, "GIT_DATE=" + $date]
  else $env
  end;
def ko_fields($hook; $d; $ver; $sha; $date): if $d.mode == "ko" then {
    importpath: $d.importpath,
    ko_config: $d.ko_config,
    go_version_file: $d.go_version_file,
    ldflags: ($d.ldflags | join("\n")),
    env: pkg_env(merge_args($hook; {}); (git_env(release_env($d.env; $ver); $d; $sha; $date) | join("\n")))
  } else {} end;
def alias_tags_for($on; $tags; $prefix; $sfx): if $on then ($tags | map($prefix + . + $sfx)) else [] end;
def with_alias($tags): if ($tags | length) > 0 then . + {alias_tags: ($tags | join(","))} else . end;
JQ

# Normalize the catalog into the version 2 model at $MODEL.
normalize_catalog() {
  local doc="$CONFIG" version
  if [[ ! -f "$doc" ]]; then
    doc="$WORK/no-docker.json"
    echo '{}' > "$doc"
    echo "No $CONFIG: reading only $LEGACY_APKO_CONFIG"
  fi
  version=$(jq -r 'if type == "object" then (.version // 1 | tostring)
                   else error("catalog must be a JSON object") end' "$doc")
  case "$version" in
    2)
      jq -c "${JQ_LIB} normalize_v2" "$doc" > "$MODEL"
      echo "Catalog: version 2 ($CONFIG)"
      ;;
    1)
      local apko_file="$WORK/no-apko.json"
      echo '{}' > "$apko_file"
      if [[ -f "$LEGACY_APKO_CONFIG" ]]; then
        apko_file="$LEGACY_APKO_CONFIG"
        echo "Catalog: legacy v1 $doc merged with $LEGACY_APKO_CONFIG"
      else
        echo "Catalog: legacy v1 $doc"
      fi
      jq -c --slurpfile a "$apko_file" "${JQ_LIB} legacy_to_v2(.; \$a[0]) | normalize_v2" "$doc" > "$MODEL"
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
  env -u GITHUB_ENV -u GITHUB_OUTPUT -u GITHUB_PATH -u GITHUB_STEP_SUMMARY -u GITHUB_STATE bash "$hook_path" > "$hook_out"
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

# True when a changed file matches at least one positive pattern and no
# negative pattern. Negative patterns are written with a leading !.
patterns_select_changed() {
  local file pattern matched_positive matched_negative
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    matched_positive=false
    matched_negative=false
    for pattern in "$@"; do
      if [[ "$pattern" == !* ]]; then
        if matches_pattern "$file" "${pattern#!}"; then
          matched_negative=true
        fi
      elif matches_pattern "$file" "$pattern"; then
        matched_positive=true
      fi
    done
    if [[ "$matched_positive" == true && "$matched_negative" == false ]]; then
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
    echo "::notice::Release tag '$REF_NAME' does not match release.tag_regex; planning nothing"
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
    echo "::notice::Release tag '$REF_NAME' names image '$svc', which is not in the catalog; planning nothing"
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
  local shared_patterns=() image_patterns=()
  mapfile -t shared_patterns < <(jq -r '.shared_paths[]?' "$MODEL")
  if [[ ${#shared_patterns[@]} -gt 0 ]] && patterns_select_changed "${shared_patterns[@]}"; then
    echo "Shared path matched: planning the full catalog"
    load_all
    return 0
  fi

  SELECT_IMAGES=()
  for n in "${ALL_IMAGES[@]+"${ALL_IMAGES[@]}"}"; do
    mapfile -t image_patterns < <(jq -r --arg n "$n" '.images[$n].paths[]?' "$MODEL")
    if [[ ${#image_patterns[@]} -gt 0 ]] && patterns_select_changed "${image_patterns[@]}"; then
      echo "Image path match: $n"
      SELECT_IMAGES+=("$n")
    fi
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

plan_context() {
  if [[ "$REF_TYPE" == "tag" ]]; then
    echo "release"
    return 0
  fi
  case "$EVENT_NAME" in
    pull_request|pull_request_target|merge_group) echo "pull_request" ;;
    *) echo "$EVENT_NAME" ;;
  esac
}

# Keeps the builders whose events include the context and drops selected images left with none.
filter_builders_by_context() {
  local context="$1" n b kept=()
  for n in "${SELECT_IMAGES[@]+"${SELECT_IMAGES[@]}"}"; do
    [[ -n "$n" ]] || continue
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      echo "::notice::Image $n builder $b is not planned for the $context context"
    done < <(jq -r --arg n "$n" --arg ctx "$context" \
      '.images[$n].builders | to_entries[] | select(.value.events | index($ctx) | not) | .key' "$MODEL")
  done
  jq -c --arg ctx "$context" \
    '.images |= with_entries(.value.builders |= with_entries(select(.value.events | index($ctx))))' \
    "$MODEL" > "$WORK/model-context.json"
  mv "$WORK/model-context.json" "$MODEL"
  for n in "${SELECT_IMAGES[@]+"${SELECT_IMAGES[@]}"}"; do
    [[ -n "$n" ]] || continue
    if jq -e --arg n "$n" '(.images[$n].builders | length) > 0' "$MODEL" >/dev/null; then
      kept+=("$n")
    else
      echo "::notice::Image $n has no builder planned for the $context context; skipped"
    fi
  done
  SELECT_IMAGES=()
  for n in "${kept[@]+"${kept[@]}"}"; do
    SELECT_IMAGES+=("$n")
  done
}

to_json_array() {
  printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length > 0)) | unique'
}

# Fails when a -slim variant lists apk-tools, busybox, or an openssl package that
# its allow_packages does not name. Version constraints are stripped before matching.
check_slim_variants() {
  local image cfg allow pkgs pkg name failed=false
  while IFS=$'\t' read -r image cfg allow; do
    [[ -n "$image" ]] || continue
    if [[ ! -f "$cfg" ]]; then
      echo "::error::image $image: -slim variant config not found: $cfg" >&2
      failed=true
      continue
    fi
    pkgs=$(yq -r '(.contents.packages // [])[]' "$cfg")
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      name="${pkg%%[=<>~!]*}"
      if [[ "$name" == "apk-tools" || "$name" == "busybox" || "$name" =~ ^openssl ]]; then
        case ",$allow," in
          *",$name,"*) continue ;;
        esac
        echo "::error::image $image: -slim variant $cfg lists $pkg; -slim variants must not include apk-tools, busybox, or openssl packages unless allow_packages names them" >&2
        failed=true
      fi
    done <<< "$pkgs"
  done < <(jq -r '.images | to_entries[] | .key as $n
      | (.value.builders.apko.configs // [])[]
      | select(.tag_suffix | endswith("-slim"))
      | [$n, .config, ((.allow_packages // []) | join(","))] | @tsv' "$MODEL")
  if [[ "$failed" == true ]]; then
    exit 1
  fi
}

main() {
  normalize_catalog
  check_slim_variants
  local hook_kv
  hook_kv=$(run_hook)

  if [[ "$REF_TYPE" == "tag" ]]; then
    plan_release
  elif [[ "$TRUSTED" != "true" && ( "$EVENT_NAME" == "pull_request" || "$EVENT_NAME" == "push" || "$EVENT_NAME" == "merge_group" ) ]]; then
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

  filter_builders_by_context "$(plan_context)"

  if [[ "$TRUSTED" != "true" ]]; then
    local skipped_name
    for skipped_name in "${SELECT_IMAGES[@]+"${SELECT_IMAGES[@]}"}"; do
      if ! jq -e --arg n "$skipped_name" 'any(.images[$n].builders[].archs[]; . == "amd64")' "$MODEL" >/dev/null; then
        echo "::notice::Image $skipped_name has no amd64 architecture; skipped on this untrusted run"
      else
        while read -r skipped_builder; do
          [[ -n "$skipped_builder" ]] || continue
          echo "::notice::Image $skipped_name builder $skipped_builder has no amd64 architecture; skipped on this untrusted run"
        done < <(jq -r --arg n "$skipped_name" '.images[$n].builders | to_entries[] | select(.value.archs | index("amd64") | not) | .key' "$MODEL")
      fi
    done
  fi

  local default_branch_run=false
  if [[ "$TRUSTED" == "true" && "$REF_TYPE" == "branch" ]]; then
    default_branch_run=true
  fi

  local images_json packages_json
  images_json=$(to_json_array "${SELECT_IMAGES[@]+"${SELECT_IMAGES[@]}"}")
  packages_json=$(to_json_array "${SELECT_PACKAGES[@]+"${SELECT_PACKAGES[@]}"}")

  local registry
  registry=$(jq -r '.registry' "$MODEL")

  local git_sha="" git_date=""
  if jq -e 'any(.images[]?; .builders.docker.git_build_args == true)' "$MODEL" >/dev/null; then
    git_sha=$(git rev-parse --verify "${HEAD_SHA}^{commit}") || {
      echo "::error::git_build_args needs commit $HEAD_SHA in the checkout" >&2
      exit 1
    }
    git_date=$(git show -s --format=%cI "$git_sha")
  fi

  local outputs
  outputs=$(jq -c -n \
    --slurpfile m "$MODEL" \
    --argjson images "$images_json" \
    --argjson pkgs "$packages_json" \
    --argjson trusted "$TRUSTED" \
    --argjson alias_on "$default_branch_run" \
    --argjson hook "$hook_kv" \
    --arg sha "$HEAD_SHA" \
    --arg git_sha "$git_sha" \
    --arg git_date "$git_date" \
    --arg ref_name "$PUBLISH_TAG" \
    --arg version "$VERSION" \
    --arg source_ref_override "$SOURCE_REF_OVERRIDE" \
    --arg is_release "$IS_RELEASE" \
    "${JQ_LIB}"'
      $m[0] as $m
      | ([ $pkgs[] as $p
          | $m.packages[$p] as $c
          | (if $trusted then $c.archs else [$c.archs[] | select(. == "x86_64")] end)[] as $arch
          | ({
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
            } + (if $c.submodules == "false" then {} else {caller_submodules: $c.submodules} end)
              + (if $c.source != null and $c.source.root then {build_dir: $c.source.path} else {} end))
        ]) as $packages
      | ([ if $trusted then empty else
            $images[] as $n
            | $m.images[$n] as $i
            | ( (if $i.builders.docker and has_member($i.builders.docker.archs; "amd64") then [{
                    id: "\($n)-docker",
                    image: $n,
                    builder: "docker",
                    arch: "amd64",
                    runner: builder_runner($i.builders.docker; "amd64"),
                    local_ref: local_ref("\($n)-docker"),
                    mode: $i.builders.docker.mode,
                    context: $i.builders.docker.context,
                    dockerfile: $i.builders.docker.dockerfile,
                    target: $i.builders.docker.target,
                    bake_file: $i.builders.docker.bake_file,
                    build_args: merge_args($hook; version_build_arg($i.builders.docker; $version) + git_build_args($i.builders.docker; $git_sha; $git_date)),
                    set: ($i.builders.docker.set | join("\n")),
                    config: "",
                    needs_packages: "",
                    suffix: "",
                    has_smoke: has_smoke($i.builders.docker.smoke),
                    smoke_commands: ($i.builders.docker.smoke.commands | tojson),
                    smoke_script: $i.builders.docker.smoke.script
                  } + ko_fields($hook; $i.builders.docker; $version; $git_sha; $git_date)] else [] end)
              + (if $i.builders.apko and has_member($i.builders.apko.archs; "amd64") then [ $i.builders.apko.configs[] as $v
                  | ($v.tag_suffix | sanitize_suffix) as $sfx
                  | {
                      id: "\($n)-apko\($sfx)",
                      image: $n,
                      builder: "apko",
                      arch: "amd64",
                      runner: builder_runner($i.builders.apko; "amd64"),
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
                      has_smoke: has_smoke($v.smoke),
                      smoke_commands: ($v.smoke.commands | tojson),
                      smoke_script: $v.smoke.script
                    }
                ] else [] end)
            ) | .[]
          end
        ]) as $build
      | ([ if $trusted | not then empty else
            $images[] as $n
            | $m.images[$n] as $i
            | ( (if $i.builders.docker and $i.builders.docker.mode != "ko" then [ $i.builders.docker.archs[] as $a | {
                    id: "\($n)-docker-\($a)",
                    image: $n,
                    builder: "docker",
                    kind: "docker-arch",
                    arch: $a,
                    runner: builder_runner($i.builders.docker; $a),
                    mode: $i.builders.docker.mode,
                    context: $i.builders.docker.context,
                    dockerfile: $i.builders.docker.dockerfile,
                    target: $i.builders.docker.target,
                    bake_file: $i.builders.docker.bake_file,
                    build_args: merge_args($hook; version_build_arg($i.builders.docker; $version) + git_build_args($i.builders.docker; $git_sha; $git_date)),
                    set: ($i.builders.docker.set | join("\n")),
                    config: "",
                    needs_packages: "",
                    suffix: "",
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
                      archs: ($i.builders.apko.archs | join(",")),
                      runner: builder_runner($i.builders.apko; "amd64"),
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
                      sha_tag: (prefix_for($m; $i; "apko") + $sha + $v.tag_suffix),
                      ref_tag: (prefix_for($m; $i; "apko") + ($ref_name | sanitize_ref) + $v.tag_suffix),
                      registry: $m.registry
                    } | with_alias(alias_tags_for($alias_on; $i.default_branch_tags; prefix_for($m; $i; "apko"); $v.tag_suffix))
                ] else [] end)
              + (if $i.builders.docker and $i.builders.docker.mode == "ko" then [{
                  id: "\($n)-ko",
                  image: $n,
                  builder: "docker",
                  kind: "ko",
                  arch: "",
                  archs: ($i.builders.docker.archs | join(",")),
                  runner: builder_runner($i.builders.docker; "amd64"),
                  mode: "ko",
                  context: $i.builders.docker.context,
                  dockerfile: "",
                  target: "",
                  bake_file: "",
                  build_args: "",
                  set: "",
                  config: "",
                  needs_packages: "",
                  suffix: "",
                  sha_tag: (prefix_for($m; $i; "docker") + $sha),
                  ref_tag: (prefix_for($m; $i; "docker") + ($ref_name | sanitize_ref)),
                  registry: $m.registry
                } + ko_fields($hook; $i.builders.docker; $version; $git_sha; $git_date) | with_alias(alias_tags_for($alias_on; $i.default_branch_tags; prefix_for($m; $i; "docker"); ""))] else [] end)
            ) | .[]
          end
        ]) as $publish
      | ([ if $trusted | not then empty else
            $images[] as $n
            | $m.images[$n] as $i
            | select($i.builders.docker != null and $i.builders.docker.mode != "ko" and ($i.builders.docker.archs | length) > 0)
            | {
                id: "\($n)-docker",
                image: $n,
                registry: $m.registry,
                sha_tag: (prefix_for($m; $i; "docker") + $sha),
                ref_tag: (prefix_for($m; $i; "docker") + ($ref_name | sanitize_ref)),
                pushed_pattern: "pushed-\($n)-docker-*",
                final_artifact: "final-\($n)-docker"
              } | with_alias(alias_tags_for($alias_on; $i.default_branch_tags; prefix_for($m; $i; "docker"); ""))
          end
        ]) as $manifest
      | ([ if $trusted | not then empty else
            $images[] as $n
            | $m.images[$n] as $i
            | ([$i.archs[], ($i.builders.docker.archs // [])[], ($i.builders.apko.archs // [])[]] | uniq_keep)[] as $a
            | ( (if $i.builders.docker and has_smoke($i.builders.docker.smoke) and has_member($i.builders.docker.archs; $a) then [{
                    id: "\($n)-\(if $i.builders.docker.mode == "ko" then "ko" else "docker" end)-\($a)",
                    image: $n,
                    builder: "docker",
                    arch: $a,
                    runner: (if $a == "amd64" then "ubuntu-24.04" else "ubuntu-24.04-arm" end),
                    registry: $m.registry,
                    final_artifact: "final-\($n)-\(if $i.builders.docker.mode == "ko" then "ko" else "docker" end)",
                    smoke_commands: ($i.builders.docker.smoke.commands | tojson),
                    smoke_script: $i.builders.docker.smoke.script,
                    expected_version: (if $i.builders.docker.smoke.verify_version and $version != "" then $version else "" end)
                  }] else [] end)
                + (if $i.builders.apko and has_member($i.builders.apko.archs; $a) then [ $i.builders.apko.configs[] as $v
                    | ($v.tag_suffix | sanitize_suffix) as $sfx
                    | select(has_smoke($v.smoke))
                    | {
                        id: "\($n)-apko\($sfx)-\($a)",
                        image: $n,
                        builder: "apko",
                        arch: $a,
                        runner: (if $a == "amd64" then "ubuntu-24.04" else "ubuntu-24.04-arm" end),
                        registry: $m.registry,
                        final_artifact: "final-\($n)-apko\($sfx)",
                        smoke_commands: ($v.smoke.commands | tojson),
                        smoke_script: $v.smoke.script,
                        expected_version: (if $v.smoke.verify_version and $version != "" then $version else "" end)
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
          has_smoke: (($smoke | length) > 0 | tostring),
          packages_matrix: ($packages | tojson),
          build_matrix: ($build | tojson),
          publish_matrix: ($publish | tojson),
          manifest_matrix: ($manifest | tojson),
          smoke_matrix: ($smoke | tojson),
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
  jq -r '"selected images: \(.selected_images)\nselected packages: \(.selected_packages)\nbuild legs: \(.build_matrix | fromjson | length)\npackage legs: \(.packages_matrix | fromjson | length)\npublish legs: \(.publish_matrix | fromjson | length)\nmanifest legs: \(.manifest_matrix | fromjson | length)\nsmoke legs: \(.smoke_matrix | fromjson | length)"' <<< "$outputs"
}

main
