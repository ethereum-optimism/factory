#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
SCRIPT="$WORK/smoke.sh"
yq -r '.runs.steps[0].run' "$ROOT/actions/smoke-test/action.yml" > "$SCRIPT"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "image" ]; then
  echo amd64
  exit 0
fi
if [ "$1" = "pull" ]; then
  exit 0
fi
shift
printf 'argv:'
printf ' [%s]' "$@"
printf '\n'
for arg in "$@"; do
  case "$arg" in
    exit3) exit 3 ;;
    version) echo "tool version 1.2.3" ;;
  esac
done
exit 0
FAKE
chmod +x "$WORK/bin/docker"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

smoke() {
  local name="$1" tests="$2" commands="${3:-[]}" version="${4:-}"
  env PATH="$WORK/bin:$PATH" IMAGE=example.invalid/img@sha256:abc IMAGE_ARCH=amd64 PULL=false \
    COMMANDS="$commands" TESTS="$tests" SCRIPT="" EXPECTED_VERSION="$version" \
    bash "$SCRIPT" > "$WORK/$name.log" 2>&1
}

smoke entrypoint '[{"entrypoint": "/usr/bin/tool", "args": ["version", "a b"], "expected_exit": 0, "expected_output": "1.2.3", "shell": ""}]' \
  || fail "entrypoint test failed: $(cat "$WORK/entrypoint.log")"
grep -q -F 'argv: [--rm] [--platform] [linux/amd64] [--entrypoint] [/usr/bin/tool] [example.invalid/img@sha256:abc] [version] [a b]' "$WORK/entrypoint.log" \
  || fail "entrypoint test ran the wrong command: $(cat "$WORK/entrypoint.log")"

smoke shell '[{"entrypoint": "/bin/sh", "shell": "tool --help | head -1", "args": [], "expected_exit": 0, "expected_output": ""}]' \
  || fail "shell test failed"
grep -q -F 'argv: [--rm] [--platform] [linux/amd64] [--entrypoint] [/bin/sh] [example.invalid/img@sha256:abc] [-c] [tool --help | head -1]' "$WORK/shell.log" \
  || fail "shell test ran the wrong command: $(cat "$WORK/shell.log")"

smoke default_entrypoint '[{"entrypoint": "", "shell": "", "args": ["--flag"], "expected_exit": 0, "expected_output": ""}]' \
  || fail "default entrypoint test failed"
grep -q -F 'argv: [--rm] [--platform] [linux/amd64] [example.invalid/img@sha256:abc] [--flag]' "$WORK/default_entrypoint.log" \
  || fail "default entrypoint test passed --entrypoint: $(cat "$WORK/default_entrypoint.log")"

smoke expected_nonzero '[{"entrypoint": "", "shell": "", "args": ["exit3"], "expected_exit": 3, "expected_output": ""}]' \
  || fail "a test expecting exit 3 failed on exit 3"

if smoke wrong_exit '[{"entrypoint": "", "shell": "", "args": ["exit3"], "expected_exit": 0, "expected_output": ""}]'; then
  fail "a test expecting exit 0 passed on exit 3"
fi
grep -q 'exited with 3, expected 0' "$WORK/wrong_exit.log" || fail "missing exit code error"

if smoke missing_output '[{"entrypoint": "", "shell": "", "args": ["x"], "expected_exit": 0, "expected_output": "not printed"}]'; then
  fail "a test with missing output passed"
fi
grep -q 'output does not contain: not printed' "$WORK/missing_output.log" || fail "missing output error"

smoke version_from_test '[{"entrypoint": "", "shell": "", "args": ["version"], "expected_exit": 0, "expected_output": ""}]' '[]' v1.2.3 \
  || fail "expected version printed by a test was not accepted"

if smoke version_missing '[{"entrypoint": "", "shell": "", "args": ["x"], "expected_exit": 0, "expected_output": ""}]' '[]' v1.2.3; then
  fail "missing expected version passed"
fi

smoke commands_only '[]' '["tool version"]' v1.2.3 || fail "plain commands no longer run"
grep -q -F 'argv: [--rm] [--platform] [linux/amd64] [--entrypoint] [tool] [example.invalid/img@sha256:abc] [version]' "$WORK/commands_only.log" \
  || fail "plain command ran the wrong command: $(cat "$WORK/commands_only.log")"

echo "smoke-test tests passed"
