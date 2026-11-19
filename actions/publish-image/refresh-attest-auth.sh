#!/usr/bin/env bash
set -euo pipefail

REGISTRY="${REGISTRY:?REGISTRY is required}"
host="${REGISTRY%%/*}"
config="${DOCKER_CONFIG_FILE:-$HOME/.docker/config.json}"

token="$(gcloud auth print-access-token)"
echo "::add-mask::$token"
auth="$(printf 'oauth2accesstoken:%s' "$token" | base64 | tr -d '\n')"

mkdir -p "$(dirname "$config")"
if [ ! -s "$config" ]; then
  echo '{}' > "$config"
fi
jq --arg host "$host" --arg auth "$auth" '.auths = ((.auths // {}) + {($host): {auth: $auth}})' \
  "$config" > "$config.tmp"
mv "$config.tmp" "$config"
