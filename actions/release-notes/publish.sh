#!/usr/bin/env bash
set -euo pipefail

image="${RELEASE_NOTES_IMAGE:?image is required}"
notes="${RELEASE_NOTES_FILE:?file is required}"
artifact_type='application/vnd.oplabs.release-notes.v1'

# Require an immutable subject: resolving a mutable tag after a concurrent
# publish could attach the notes to a different release.
if [[ ! "$image" =~ ^[^@[:space:]]+/[^@[:space:]]+@sha256:[a-f0-9]{64}$ ]]; then
  echo 'image must be a fully qualified reference with a sha256 digest' >&2
  exit 1
fi
if [[ ! -f "$notes" || ! -s "$notes" ]]; then
  echo 'release notes must be a nonempty file' >&2
  exit 1
fi

# Use a stable, safe filename inside the artifact, regardless of the source path.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -- "$notes" "$staging/RELEASE_NOTES.md"

(
  cd "$staging"
  oras attach \
    --distribution-spec v1.1-referrers-api \
    --artifact-type "$artifact_type" \
    --annotation 'org.opencontainers.image.title=Release notes' \
    --export-manifest manifest.json \
    "$image" RELEASE_NOTES.md:text/markdown
)

# Hash the exact exported manifest bytes, avoiding dependence on CLI output format.
digest="$(python3 -c 'import hashlib, sys; print("sha256:" + hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$staging/manifest.json")"
reference="${image%@*}@$digest"
echo "reference=$reference" >> "$GITHUB_OUTPUT"
# shellcheck disable=SC2016 # Markdown backticks are literal.
printf '\nRelease notes: `%s`\n' "$reference" >> "$GITHUB_STEP_SUMMARY"
