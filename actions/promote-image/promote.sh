#!/usr/bin/env bash
set -euo pipefail

: "${KIND:?}" "${SOURCE:?}" "${DIGEST:?}" "${DEST:?}" "${LEG_ID:?}" "${RUNNER_TEMP_DIR:?}"
if [[ ! "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "::error::invalid digest for $LEG_ID: '$DIGEST'" >&2
  exit 1
fi

manifest_digest() {
  printf 'sha256:%s' "$(crane manifest "$1" | sha256sum | awk '{print $1}')"
}

staged="$(manifest_digest "${SOURCE}@${DIGEST}")"
if [ "$staged" != "$DIGEST" ]; then
  echo "::error::staged manifest for ${SOURCE}@${DIGEST} hashes to ${staged}" >&2
  exit 1
fi

tags=()
case "$KIND" in
  docker-arch)
    crane copy "${SOURCE}@${DIGEST}" "${DEST}@${DIGEST}"
    ;;
  apko|ko)
    : "${SHA_TAG:?}" "${REF_TAG:?}"
    tags=("$SHA_TAG" "$REF_TAG")
    if [ -n "${ALIAS_TAGS:-}" ]; then
      IFS=',' read -ra aliases <<< "$ALIAS_TAGS"
      for alias_tag in "${aliases[@]}"; do
        [ -n "$alias_tag" ] && tags+=("$alias_tag")
      done
    fi
    crane copy "${SOURCE}@${DIGEST}" "${DEST}:${SHA_TAG}"
    for tag in "${tags[@]:1}"; do
      crane tag "${DEST}:${SHA_TAG}" "$tag"
    done
    ;;
  *)
    echo "::error::unknown kind: $KIND" >&2
    exit 1
    ;;
esac

while IFS= read -r attachment; do
  [ -n "$attachment" ] || continue
  crane copy "${SOURCE}:${attachment}" "${DEST}:${attachment}"
  echo "copied attachment ${attachment}"
done < <(crane ls "$SOURCE" | grep -E '^sha256-[0-9a-f]{64}(\.[a-z]+)?$' || true)

published="$(manifest_digest "${DEST}@${DIGEST}")"
if [ "$published" != "$DIGEST" ]; then
  echo "::error::${DEST}@${DIGEST} hashes to ${published}, not the smoke-tested digest" >&2
  exit 1
fi
for tag in "${tags[@]+"${tags[@]}"}"; do
  resolved="$(crane digest "${DEST}:${tag}")"
  if [ "$resolved" != "$DIGEST" ]; then
    echo "::error::${DEST}:${tag} resolves to ${resolved}, not the smoke-tested digest ${DIGEST}" >&2
    exit 1
  fi
done

printf '%s\n' "$DIGEST" > "${RUNNER_TEMP_DIR}/${LEG_ID}.txt"
echo "digest=$DIGEST" >> "$GITHUB_OUTPUT"
echo "promoted $LEG_ID: ${DEST}@${DIGEST} (tags: ${tags[*]:-none})"
