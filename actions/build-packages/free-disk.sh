#!/usr/bin/env bash
# Removes preinstalled hosted-runner toolchains and prints disk usage before and
# after.
#
# Usage: free-disk.sh [path...]
# Missing paths are skipped. FREE_DISK_SUDO sets the privilege prefix for rm
# and defaults to sudo; set it to an empty string to run rm directly.
set -euo pipefail

if [ "$#" -gt 0 ]; then
  paths=("$@")
else
  paths=(
    /usr/local/lib/android
    /usr/share/dotnet
    /opt/ghc
    /usr/local/.ghcup
    /opt/hostedtoolcache/CodeQL
    /usr/share/swift
  )
fi

privileged="${FREE_DISK_SUDO-sudo}"

echo "disk usage before:"
df -h /

for path in "${paths[@]}"; do
  if [ -e "$path" ]; then
    echo "removing $path"
    # shellcheck disable=SC2086
    $privileged rm -rf -- "$path"
  else
    echo "skipping missing $path"
  fi
done

echo "disk usage after:"
df -h /
