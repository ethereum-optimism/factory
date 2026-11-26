#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <apko|melange> <tag>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
tool="$1"
tag="$2"

case "$tool" in
  apko | melange) ;;
  *)
    echo "error: unknown tool '${tool}'; expected apko or melange" >&2
    exit 2
    ;;
esac

if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-op\.[0-9]+$ ]]; then
  echo "error: tag '${tag}' does not match v<major>.<minor>.<patch>-op.<n>" >&2
  exit 2
fi

repo="ethereum-optimism/${tool}"
bin="op-${tool}"
signer_workflow="ethereum-optimism/factory/.github/workflows/goreleaser.yaml"
platforms=(linux_amd64 linux_arm64 darwin_arm64)

immutable="$(gh release view "$tag" --repo "$repo" --json isImmutable --jq '.isImmutable')"
if [ "$immutable" != "true" ]; then
  echo "error: release ${repo}@${tag} is not immutable" >&2
  exit 1
fi

gh release verify "$tag" --repo "$repo" >&2

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/bump-${bin}.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

digest_linux_amd64=""
digest_linux_arm64=""
digest_darwin_arm64=""
for platform in "${platforms[@]}"; do
  asset="${bin}_${tag#v}_${platform}.tar.gz"
  gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$work_dir" >&2
  file="${work_dir}/${asset}"
  [ -f "$file" ] || {
    echo "error: ${asset} was not downloaded" >&2
    exit 1
  }
  gh release verify-asset "$tag" "$file" --repo "$repo" >&2
  gh attestation verify "$file" \
    --repo "$repo" \
    --signer-workflow "$signer_workflow" \
    --source-ref "refs/tags/${tag}" \
    --deny-self-hosted-runners >&2
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$file" | awk '{ print $1 }')"
  else
    digest="$(shasum -a 256 "$file" | awk '{ print $1 }')"
  fi
  if ! [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: could not compute sha256 of ${asset}" >&2
    exit 1
  fi
  printf -v "digest_${platform}" '%s' "$digest"
done

cat <<EOF
        VERSION: ${tag}
        SHA256_LINUX_AMD64: ${digest_linux_amd64}
        SHA256_LINUX_ARM64: ${digest_linux_arm64}
        SHA256_DARWIN_ARM64: ${digest_darwin_arm64}
EOF
