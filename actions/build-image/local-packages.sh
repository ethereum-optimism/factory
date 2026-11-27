#!/usr/bin/env bash
# Usage: local-packages.sh <lockfile> <digests_dir> <archs>
# Prints one <name>=sha256:<hex> line for every digest of every package that
# the lock file marks local for the given apko architectures (comma-separated,
# amd64 or arm64), read from the apk-digests files in digests_dir. Fails when
# a local package has no digest.
set -euo pipefail

lockfile="${1:?lock file required}"
digests_dir="${2:-}"
archs="${3:?architectures required}"

apk_archs=()
IFS=',' read -ra requested <<< "$archs"
for arch in "${requested[@]}"; do
  arch="${arch// /}"
  case "$arch" in
    amd64|x86_64) apk_archs+=(x86_64) ;;
    arm64|aarch64) apk_archs+=(aarch64) ;;
    "") ;;
    *) echo "::error::unsupported architecture: $arch" >&2; exit 1 ;;
  esac
done

names="$(jq -r --args '.contents.packages[] | select(.local == true and (.architecture as $a | $ARGS.positional | index($a))) | .name' \
  "${apk_archs[@]}" < "$lockfile" | sort -u)"
[ -n "$names" ] || exit 0

if [ -z "$digests_dir" ] || [ ! -d "$digests_dir" ]; then
  echo "::error::$lockfile locks local packages but no package digests were downloaded" >&2
  exit 1
fi

all_digests="$(cat "$digests_dir"/*.txt 2>/dev/null || true)"
missing=()
while IFS= read -r name; do
  found="$(awk -F= -v n="$name" '$1 == n && $2 ~ /^sha256:[0-9a-f]{64}$/ { print $2 }' <<< "$all_digests" | sort -u)"
  if [ -z "$found" ]; then
    missing+=("$name")
    continue
  fi
  while IFS= read -r digest; do
    printf '%s=%s\n' "$name" "$digest"
  done <<< "$found"
done <<< "$names"

if [ "${#missing[@]}" -gt 0 ]; then
  echo "::error::$lockfile locks local packages built in no package leg of this run: ${missing[*]}" >&2
  exit 1
fi
