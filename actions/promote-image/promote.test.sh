#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROMOTE="$ROOT/actions/promote-image/promote.sh"
WORK="$(mktemp -d)"
STORE="$WORK/store"
mkdir -p "$WORK/bin" "$STORE"

if ! command -v sha256sum > /dev/null; then
  cat > "$WORK/bin/sha256sum" <<'SHIM'
#!/usr/bin/env bash
exec shasum -a 256 "$@"
SHIM
  chmod +x "$WORK/bin/sha256sum"
fi

cat > "$WORK/bin/crane" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
key() { printf '%s' "$1" | tr '/:@' '___'; }
repo_of() { local r="${1%@*}"; if [[ "${r##*/}" == *:* ]]; then r="${r%:*}"; fi; printf '%s' "$r"; }
cmd="$1"; shift
case "$cmd" in
  manifest)
    cat "$STORE/$(key "$1")"
    ;;
  copy)
    [ -f "$STORE/$(key "$1")" ] || { echo "no such ref $1" >&2; exit 1; }
    if [ -n "${CORRUPT_COPY:-}" ]; then
      printf 'corrupted' > "$STORE/$(key "$2")"
    else
      cp "$STORE/$(key "$1")" "$STORE/$(key "$2")"
    fi
    digest="sha256:$(sha256sum < "$STORE/$(key "$2")" | awk '{print $1}')"
    alias="$STORE/$(key "$(repo_of "$2")@$digest")"
    [ "$alias" = "$STORE/$(key "$2")" ] || cp "$STORE/$(key "$2")" "$alias"
    echo "$2" >> "$STORE/log"
    ;;
  tag)
    src="$1"; tag="$2"
    cp "$STORE/$(key "$src")" "$STORE/$(key "$(repo_of "$src"):$tag")"
    echo "$(repo_of "$src"):$tag" >> "$STORE/log"
    ;;
  digest)
    printf 'sha256:%s\n' "$(sha256sum < "$STORE/$(key "$1")" | awk '{print $1}')"
    ;;
  ls)
    cat "$STORE/ls-$(key "$1")" 2>/dev/null || true
    ;;
  *) echo "unexpected crane $cmd" >&2; exit 1 ;;
esac
FAKE
chmod +x "$WORK/bin/crane"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

key() { printf '%s' "$1" | tr '/:@' '___'; }
SRC=localhost:5000/group/app
DEST=registry.example.invalid/images/group/app
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json"}' > "$WORK/index.json"
DIGEST="sha256:$(PATH="$WORK/bin:$PATH" sha256sum < "$WORK/index.json" | awk '{print $1}')"
cp "$WORK/index.json" "$STORE/$(key "$SRC@$DIGEST")"
ATTACH="sha256-${DIGEST#sha256:}.sbom"
cp "$WORK/index.json" "$STORE/$(key "$SRC:$ATTACH")"
printf '%s\nlatest-local\n' "$ATTACH" > "$STORE/ls-$(key "$SRC")"

promote() {
  local name="$1"
  shift
  env PATH="$WORK/bin:$PATH" STORE="$STORE" SOURCE="$SRC" DEST="$DEST" LEG_ID="$name" \
    RUNNER_TEMP_DIR="$WORK" GITHUB_OUTPUT="$WORK/$name.out" "$@" \
    bash "$PROMOTE" > "$WORK/$name.log" 2>&1
}

promote tagged KIND=apko DIGEST="$DIGEST" SHA_TAG=v1-20261127-0123456789ab REF_TAG=v1 ALIAS_TAGS=latest \
  || fail "tagged promote failed: $(cat "$WORK/tagged.log")"
for tag in v1-20261127-0123456789ab v1 latest "$ATTACH"; do
  grep -q -x -F "$DEST:$tag" "$STORE/log" || fail "tag $tag was not published"
done
grep -q -x -F "digest=$DIGEST" "$WORK/tagged.out" || fail "promote did not output the digest"
[ "$(cat "$WORK/tagged.txt")" = "$DIGEST" ] || fail "promote did not write the digest file"
grep -q -x -F "$DEST:latest-local" "$STORE/log" && fail "promote copied a tag that is not an attachment"

: > "$STORE/log"
promote by_digest KIND=docker-arch DIGEST="$DIGEST" || fail "docker-arch promote failed: $(cat "$WORK/by_digest.log")"
grep -q -x -F "$DEST@$DIGEST" "$STORE/log" || fail "docker-arch leg was not copied by digest"

if promote corrupt KIND=apko DIGEST="$DIGEST" SHA_TAG=abc REF_TAG=main CORRUPT_COPY=1; then
  fail "promote accepted a published manifest that differs from the tested digest"
fi
grep -q 'not the smoke-tested digest' "$WORK/corrupt.log" || fail "missing digest mismatch error"

if promote bad_digest KIND=apko DIGEST=sha256:abc SHA_TAG=abc REF_TAG=main; then
  fail "promote accepted an invalid digest"
fi

other="sha256:$(printf 'other' | PATH="$WORK/bin:$PATH" sha256sum | awk '{print $1}')"
cp "$WORK/index.json" "$STORE/$(key "$SRC@$other")"
if promote staged_mismatch KIND=apko DIGEST="$other" SHA_TAG=abc REF_TAG=main; then
  fail "promote accepted a staged manifest that does not hash to its digest"
fi
grep -q 'staged manifest' "$WORK/staged_mismatch.log" || fail "missing staged mismatch error"

echo "promote-image tests passed"
