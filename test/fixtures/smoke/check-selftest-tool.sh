#!/usr/bin/env bash
set -euo pipefail
: "${IMAGE:?IMAGE must be set}"
output="$(docker run --rm --entrypoint selftest-tool "$IMAGE")"
if [ "$output" != "selftest-tool 1.0.0" ]; then
  echo "unexpected output: $output" >&2
  exit 1
fi
output="$(docker run --rm --entrypoint selftest-gotool "$IMAGE")"
if [ "$output" != "selftest-gotool 1.0.0" ]; then
  echo "unexpected output: $output" >&2
  exit 1
fi
sbom="$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'cat /var/lib/db/sbom/selftest-gotool-*.spdx.json')"
purls="$(jq -r '.packages[].externalRefs[]? | select(.referenceType == "purl") | .referenceLocator' <<< "$sbom")"
golang="$(grep '^pkg:golang/' <<< "$purls" || true)"
echo "selftest-gotool SBOM pkg:golang purls:"
printf '%s\n' "${golang:-(none)}"
if ! grep -q '^pkg:golang/stdlib@' <<< "$golang"; then
  echo "selftest-gotool SBOM has no pkg:golang/stdlib purl" >&2
  exit 1
fi
