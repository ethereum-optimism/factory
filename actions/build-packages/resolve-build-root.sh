#!/usr/bin/env bash
# Prints the absolute directory a package build treats as the repository root.
#
# Usage: resolve-build-root.sh <workspace> <build_dir>
set -euo pipefail

workspace="${1:?workspace required}"
build_dir="${2:-.}"
if [[ -z "$build_dir" ]]; then
  build_dir="."
fi

if [[ ! "$build_dir" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "$build_dir" == /* ]] || [[ "/$build_dir/" == *"/../"* ]]; then
  echo "::error::build_dir must be a relative path without '..': $build_dir" >&2
  exit 1
fi

root="${workspace}/${build_dir}"
if [[ ! -d "$root" ]]; then
  echo "::error::build_dir does not exist in the workspace: $build_dir" >&2
  exit 1
fi

(cd "$root" && pwd -P)
