# shellcheck shell=bash
# shellcheck disable=SC2034
# Sourced by publish-image and the apko self-test.
# Usage: apko_container_layout <config_dir> <out_dir>
# Sets: apko_mounts (array) and apko_workdir.
apko_container_layout() {
  local config_dir="$1" out_dir="$2" repo_root
  apko_mounts=(-v "${config_dir}:${config_dir}:ro" -v "${out_dir}:${out_dir}")
  apko_workdir="$out_dir"
  repo_root="$(git -C "$config_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$repo_root" ] && [ -d "${repo_root}/.git" ]; then
    apko_mounts+=(-v "${repo_root}/.git:${repo_root}/.git:ro")
    apko_workdir="$repo_root"
  fi
}
