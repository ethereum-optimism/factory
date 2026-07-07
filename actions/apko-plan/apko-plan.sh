#!/usr/bin/env bash
# Plan melange + apko + smoke CI matrices from a nexus catalog JSON file.
#
# Usage: apko-plan.sh <catalog.json>
#
# Writes GITHUB_OUTPUT:
#   has_builds=true|false
#   melange_matrix_json=[...]
#   apko_matrix_json=[...]
#   smoke_matrix_json=[...]
#   is_release=true|false
#
# Requires: checkout with fetch-depth 0 on pull_request; jq.
set -euo pipefail

CONFIG="${1:?catalog path required}"

EVENT_NAME="${GITHUB_EVENT_NAME:-workflow_dispatch}"
REF_TYPE="${GITHUB_REF_TYPE:-}"
REF_NAME="${GITHUB_REF_NAME:-}"
BASE_SHA=""
HEAD_SHA="${GITHUB_SHA:-HEAD}"
PUBLISH_TAG="$REF_NAME"
RELEASE_SERVICE=""
RELEASE_VERSION=""
RELEASE_SOURCE_REF=""

if [[ -z "$REF_TYPE" && -n "${GITHUB_REF:-}" ]]; then
  if [[ "$GITHUB_REF" == refs/tags/* ]]; then
    REF_TYPE="tag"
    REF_NAME="${REF_NAME:-${GITHUB_REF#refs/tags/}}"
  elif [[ "$GITHUB_REF" == refs/heads/* ]]; then
    REF_TYPE="branch"
    REF_NAME="${REF_NAME:-${GITHUB_REF#refs/heads/}}"
  fi
fi

if [[ "$EVENT_NAME" == "pull_request" && -f "${GITHUB_EVENT_PATH:-}" ]]; then
  BASE_SHA=$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH")
  HEAD_SHA=$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH")
  if [[ -z "$HEAD_SHA" ]]; then
    HEAD_SHA="${GITHUB_SHA:-HEAD}"
  fi
fi

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

file_matches_any() {
  local file="$1"; shift
  local pattern
  for pattern in "$@"; do
    [[ -z "$pattern" ]] && continue
    matches_pattern "$file" "$pattern" && return 0
  done
  return 1
}

emit_outputs() {
  local apko_matrix="$1" melange_matrix="$2"
  local is_release="${3:-false}"
  local has_builds
  local smoke_matrix
  has_builds=$( [[ $(echo "$apko_matrix" | jq 'length') -gt 0 ]] && echo true || echo false )
  smoke_matrix=$(echo "$apko_matrix" | jq -c --slurpfile config "$CONFIG" '
    def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
    def smoke_runner($smoke_runners; $arch):
      ($smoke_runners[$arch] // (if $arch == "arm64" then "ubuntu-24.04-arm" else "ubuntu-slim" end));
    ($config[0].smoke_runners // {}) as $smoke_runners
    | [.[] | select((.smoke_test // "") != "")
      | . as $image
      | (($image.archs // "amd64,arm64") | split(",") | map(trim) | map(select(length > 0)))[] as $arch
      | {
          service: $image.service,
          arch: $arch,
          runner: smoke_runner($smoke_runners; $arch),
          smoke_test: $image.smoke_test
        }]
  ')
  {
    echo "has_builds=$has_builds"
    echo "melange_matrix_json=$melange_matrix"
    echo "apko_matrix_json=$apko_matrix"
    echo "smoke_matrix_json=$smoke_matrix"
    echo "is_release=$is_release"
  } >> "$GITHUB_OUTPUT"
  echo "has_builds=$has_builds"
  echo "is_release=$is_release"
  echo "melange legs: $(echo "$melange_matrix" | jq 'length')"
  echo "apko images: $(echo "$apko_matrix" | jq 'length')"
  echo "smoke tests: $(echo "$smoke_matrix" | jq 'length')"
}

build_full_image_set() {
  jq -r '.images | keys[]' "$CONFIG" | sort -u
}

build_full_melange_set() {
  jq -r '.melange | keys[]' "$CONFIG" | sort -u
}

melange_keywords_for_image() {
  local image="$1"
  jq -r --arg img "$image" '.images[$img].needs_melange[]?' "$CONFIG"
}

images_for_melange_keyword() {
  local keyword="$1"
  jq -r --arg kw "$keyword" '
    .images
    | to_entries[]
    | select(.value.needs_melange[]? == $kw)
    | .key
  ' "$CONFIG"
}

melange_config_path() {
  local keyword="$1"
  jq -r --arg kw "$keyword" '
    .melange[$kw].config // ("melange/" + $kw + ".yaml")
  ' "$CONFIG"
}

pipelines_for_melange_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 0
  grep -oE 'uses:[[:space:]]*[A-Za-z0-9_-]+/[A-Za-z0-9_-]+' "$cfg" \
    | awk '{print $2}' \
    | cut -d/ -f1 \
    | sort -u
}

build_apko_matrix() {
  local -n _images="$1"
  local publish_tag="${2:-$REF_NAME}"
  local apko_archs
  apko_archs=$(jq -r '.apko_archs // "amd64,arm64"' "$CONFIG")
  local names_json
  names_json=$(printf '%s\n' "${_images[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  jq -c \
    --argjson names "$names_json" \
    --arg apko_archs "$apko_archs" \
    --arg publish_tag "$publish_tag" \
    '
      [.images as $images | $names[] as $name
        | $images[$name]
        | {
            service: $name,
            needs_melange_apks: (.needs_melange | join(",")),
            archs: (.apko_archs // $apko_archs),
            publish_tag: $publish_tag,
            smoke_test: (.smoke_test // "")
          }
      ]
    ' "$CONFIG"
}

runner_for() {
  local keyword="$1" arch="$2"
  jq -r --arg kw "$keyword" --arg arch "$arch" '
    .melange[$kw].runners[$arch]
    // .default_runners[$arch]
    // (if $arch == "aarch64" then "ubuntu-24.04-arm" else "ubuntu-24.04" end)
  ' "$CONFIG"
}

build_melange_matrix() {
  local -n _keywords="$1"
  local source_ref_override="${2:-}"
  local melange_archs_json
  melange_archs_json=$(jq -c '.melange_archs // ["x86_64","aarch64"]' "$CONFIG")
  local keywords_json
  keywords_json=$(printf '%s\n' "${_keywords[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  jq -c \
    --argjson keywords "$keywords_json" \
    --argjson melange_archs "$melange_archs_json" \
    --arg source_ref_override "$source_ref_override" \
    '
      def runner($kw; $arch):
        (.melange[$kw].runners[$arch]
          // .default_runners[$arch]
          // (if $arch == "aarch64" then "ubuntu-24.04-arm" else "ubuntu-24.04" end));
      [.melange as $melange | $keywords[] as $kw | $melange_archs[] as $arch
        | $melange[$kw] as $cfg
        | {
            stack: $kw,
            arch: $arch,
            runner: runner($kw; $arch),
            melange_config: ($cfg.config // ("melange/" + $kw + ".yaml")),
            checkout_source: (($cfg.source // null) != null),
            source_repository: ($cfg.source.repository // ""),
            source_ref: (if $source_ref_override != "" and (($cfg.source // null) != null) then $source_ref_override else ($cfg.source.ref // "") end),
            source_path: ($cfg.source.path // "."),
            source_submodules: ($cfg.source_submodules // "false"),
            use_github_app_token: ($cfg.use_github_app_token // false),
            use_gha_cache: ($cfg.use_gha_cache // false),
            cache_key_files: (
              if ($cfg.cache_key_files // []) | length > 0 then
                ($cfg.cache_key_files | join(","))
              else "" end
            )
          }
      ]
    ' "$CONFIG"
}

render_release_template() {
  local value="$1"
  value="${value//\$\{service\}/$RELEASE_SERVICE}"
  value="${value//\$\{version\}/$RELEASE_VERSION}"
  value="${value//\$\{ref_name\}/$REF_NAME}"
  printf '%s' "$value"
}

plan_release_tag() {
  local regex service_match version_match service_template publish_template source_ref_template
  local service version

  regex=$(jq -r '.release.tag_regex // "^([^/]+)/(v.+)$"' "$CONFIG")
  service_match=$(jq -r '.release.service_match // 1' "$CONFIG")
  version_match=$(jq -r '.release.version_match // 2' "$CONFIG")

  if ! [[ "$service_match" =~ ^[0-9]+$ && "$version_match" =~ ^[0-9]+$ ]]; then
    echo "::error::release.service_match and release.version_match must be numeric capture indexes" >&2
    exit 1
  fi

  if [[ ! "$REF_NAME" =~ $regex ]]; then
    echo "Tag ref '$REF_NAME' does not match release tag regex for $CONFIG; no builds"
    emit_outputs "[]" "[]" "true"
    exit 0
  fi
  if (( service_match >= ${#BASH_REMATCH[@]} || version_match >= ${#BASH_REMATCH[@]} )); then
    echo "::error::release tag regex '$regex' did not provide capture indexes service=$service_match version=$version_match for '$REF_NAME'" >&2
    exit 1
  fi

  service="${BASH_REMATCH[$service_match]}"
  version="${BASH_REMATCH[$version_match]}"
  service_template=$(jq -r '.release.service // ""' "$CONFIG")
  if [[ -n "$service_template" ]]; then
    RELEASE_SERVICE="$service"
    RELEASE_VERSION="$version"
    service=$(render_release_template "$service_template")
  fi

  if ! jq -e --arg img "$service" '.images[$img]' "$CONFIG" >/dev/null 2>&1; then
    echo "Tag ref '$REF_NAME' resolved to service '$service', which is not in $CONFIG; no builds"
    emit_outputs "[]" "[]" "true"
    exit 0
  fi

  RELEASE_SERVICE="$service"
  RELEASE_VERSION="$version"
  publish_template=$(jq -r '.release.publish_tag // "${version}"' "$CONFIG")
  source_ref_template=$(jq -r '.release.source_ref // ""' "$CONFIG")
  PUBLISH_TAG=$(render_release_template "$publish_template")
  RELEASE_SOURCE_REF=$(render_release_template "$source_ref_template")

  echo "Release tag resolved: service=$RELEASE_SERVICE version=$RELEASE_VERSION publish_tag=$PUBLISH_TAG source_ref=${RELEASE_SOURCE_REF:-<catalog default>}"
  add_image "$RELEASE_SERVICE"
}

declare -a AFFECTED_IMAGES=()
declare -A AFFECTED_IMAGE_SET=()
declare -A AFFECTED_MELANGE=()

add_image() {
  local name="$1"
  [[ -n "${AFFECTED_IMAGE_SET[$name]+x}" ]] && return 0
  AFFECTED_IMAGE_SET["$name"]=1
  AFFECTED_IMAGES+=("$name")
  while IFS= read -r kw; do
    [[ -n "$kw" ]] && AFFECTED_MELANGE["$kw"]=1
  done < <(melange_keywords_for_image "$name")
}

add_melange_keyword() {
  local kw="$1"
  AFFECTED_MELANGE["$kw"]=1
  while IFS= read -r img; do
    [[ -n "$img" ]] && add_image "$img"
  done < <(images_for_melange_keyword "$kw")
}

if [[ ! -f "$CONFIG" ]]; then
  echo "::error::Catalog not found: $CONFIG" >&2
  exit 1
fi

if [[ "$REF_TYPE" == "tag" ]]; then
  plan_release_tag
elif [[ "$EVENT_NAME" != "pull_request" ]]; then
  echo "Non-PR event ($EVENT_NAME): planning full catalog"
  mapfile -t AFFECTED_IMAGES < <(build_full_image_set)
  while IFS= read -r kw; do
    AFFECTED_MELANGE["$kw"]=1
  done < <(build_full_melange_set)
else
  CHANGED_FILES=""
  DIFF_OK=false
  if [[ -n "$BASE_SHA" && -n "$HEAD_SHA" ]]; then
    git fetch --no-tags origin "$BASE_SHA" "$HEAD_SHA" >&2 || true
    if git rev-parse --verify "${BASE_SHA}^{commit}" >/dev/null 2>&1 \
       && git rev-parse --verify "${HEAD_SHA}^{commit}" >/dev/null 2>&1; then
      CHANGED_FILES=$(git diff --name-only "${BASE_SHA}...${HEAD_SHA}" 2>/dev/null || true)
      DIFF_OK=true
    fi
  fi
  if [[ "$DIFF_OK" != "true" ]]; then
    echo "::warning::Could not compute PR diff (base=${BASE_SHA:-?} head=${HEAD_SHA:-?}); planning full catalog"
    mapfile -t AFFECTED_IMAGES < <(build_full_image_set)
    while IFS= read -r kw; do
      AFFECTED_MELANGE["$kw"]=1
    done < <(build_full_melange_set)
  elif [[ -z "$CHANGED_FILES" ]]; then
    echo "PR diff empty (${BASE_SHA}...${HEAD_SHA}): no builds"
    emit_outputs "[]" "[]"
    exit 0
  else
    echo "Changed files (${BASE_SHA}...${HEAD_SHA}):"
    echo "$CHANGED_FILES" | head -50
    BUILD_ALL=false

    while IFS= read -r pattern; do
      [[ -z "$pattern" ]] && continue
      while IFS= read -r file; do
        if matches_pattern "$file" "$pattern"; then
          echo "shared_paths match: $file ~ $pattern → full catalog"
          BUILD_ALL=true
          break 2
        fi
      done <<< "$CHANGED_FILES"
    done < <(jq -r '.shared_paths[]?' "$CONFIG")

    if [[ "$BUILD_ALL" == "true" ]]; then
      mapfile -t AFFECTED_IMAGES < <(build_full_image_set)
      while IFS= read -r kw; do
        AFFECTED_MELANGE["$kw"]=1
      done < <(build_full_melange_set)
    else
      declare -A TYPE_BUILD_ALL=()
      while IFS= read -r type_name; do
        [[ -z "$type_name" ]] && continue
        while IFS= read -r pattern; do
          [[ -z "$pattern" ]] && continue
          while IFS= read -r file; do
            if matches_pattern "$file" "$pattern"; then
              echo "shared_${type_name}_paths match: $file ~ $pattern"
              TYPE_BUILD_ALL["$type_name"]=1
              break 2
            fi
          done <<< "$CHANGED_FILES"
        done < <(jq -r --arg key "shared_${type_name}_paths" '.[$key][]?' "$CONFIG")
      done < <(jq -r 'keys[] | select(test("^shared_.*_paths$")) | sub("^shared_"; "") | sub("_paths$"; "")' "$CONFIG")

      for type_name in "${!TYPE_BUILD_ALL[@]}"; do
        while IFS= read -r name; do
          add_image "$name"
        done < <(jq -r --arg t "$type_name" '.images | to_entries[] | select(.value.type == $t) | .key' "$CONFIG")
      done

      while IFS= read -r entry; do
        name=$(echo "$entry" | jq -r '.key')
        [[ -n "${AFFECTED_IMAGE_SET[$name]+x}" ]] && continue

        mapfile -t patterns < <(echo "$entry" | jq -r '(.value.paths // [])[], (.value.nexus_paths // [])[]')
        for pattern in "${patterns[@]}"; do
          [[ -z "$pattern" ]] && continue
          while IFS= read -r file; do
            if matches_pattern "$file" "$pattern"; then
              echo "image path match: $file ~ $pattern → $name"
              add_image "$name"
              break 2
            fi
          done <<< "$CHANGED_FILES"
        done
      done < <(jq -c '.images | to_entries[]' "$CONFIG")

      while IFS= read -r kw; do
        cfg=$(melange_config_path "$kw")
        while IFS= read -r file; do
          if [[ "$file" == "$cfg" ]]; then
            echo "melange config changed → $kw"
            add_melange_keyword "$kw"
            break
          fi
        done <<< "$CHANGED_FILES"

        while IFS= read -r file; do
          if [[ "$file" == "apko/${kw}.yaml" ]]; then
            echo "apko config changed → $kw"
            add_melange_keyword "$kw"
            break
          fi
        done <<< "$CHANGED_FILES"

        while IFS= read -r pipe; do
          [[ -z "$pipe" ]] && continue
          while IFS= read -r file; do
            if matches_pattern "$file" "pipelines/${pipe}/**"; then
              echo "pipeline ${pipe} changed → melange ${kw}"
              add_melange_keyword "$kw"
              break 2
            fi
          done <<< "$CHANGED_FILES"
        done < <(pipelines_for_melange_config "$cfg")
      done < <(build_full_melange_set)
    fi
  fi
fi

if [[ ${#AFFECTED_IMAGES[@]} -eq 0 ]]; then
  echo "No affected images"
  emit_outputs "[]" "[]"
  exit 0
fi

mapfile -t SORTED_IMAGES < <(printf '%s\n' "${AFFECTED_IMAGES[@]}" | sort -u)
mapfile -t SORTED_MELANGE < <(printf '%s\n' "${!AFFECTED_MELANGE[@]}" | sort -u)

APKO_MATRIX=$(build_apko_matrix SORTED_IMAGES "$PUBLISH_TAG")
MELANGE_MATRIX=$(build_melange_matrix SORTED_MELANGE "$RELEASE_SOURCE_REF")

echo "Affected images: ${SORTED_IMAGES[*]}"
echo "Melange keywords: ${SORTED_MELANGE[*]}"

emit_outputs "$APKO_MATRIX" "$MELANGE_MATRIX" "$([[ "$REF_TYPE" == "tag" ]] && echo true || echo false)"
