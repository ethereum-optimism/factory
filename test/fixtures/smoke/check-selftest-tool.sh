#!/usr/bin/env bash
set -euo pipefail
output="$(docker run --rm --entrypoint selftest-tool "$IMAGE")"
if [ "$output" != "selftest-tool 1.0.0" ]; then
  echo "unexpected output: $output" >&2
  exit 1
fi
