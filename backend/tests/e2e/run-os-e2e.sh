#!/usr/bin/env bash
# Run OS-level e2e drivers. Expects to be running INSIDE the Limn
# Linux container — Xvfb on :99 already up, xdotool on PATH, Limn
# Linux binary at /limn/sioyek/limn (or $LIMN_BIN override).
#
# To run from macOS host, use backend/tests/run-all-tiers.sh which
# handles the docker run wrapping.

set -u

# Sanity-check we have the container env we expect.
if [ -z "${DISPLAY:-}" ]; then
  echo "✗ DISPLAY not set — this script must run inside the Limn container"
  echo "  with Xvfb already running on :99."
  echo "  From host: backend/tests/run-all-tiers.sh"
  exit 2
fi
if ! command -v xdotool >/dev/null 2>&1; then
  echo "✗ xdotool not found on PATH"
  exit 2
fi
if [ ! -x "${LIMN_BIN:-/limn/sioyek/limn}" ]; then
  echo "✗ Limn binary not at ${LIMN_BIN:-/limn/sioyek/limn}"
  exit 2
fi

E2E_DIR="$(cd "$(dirname "$0")" && pwd)"

export LIMN_BACKEND_DIR="${LIMN_BACKEND_DIR:-/limn/backend/}"

pass=0
fail=0
fails=()

for driver in "$E2E_DIR"/batch-os-*.lisp; do
  [ -f "$driver" ] || continue
  name="$(basename "$driver" .lisp)"
  echo "── $name ─────────────────────────────────────"
  # ONE sbcl invocation per driver — capture both stdout for grep
  # snippet AND exit code. Previously ran twice (once for grep, once
  # for exit) which doubled X-state pollution and caused cumulative
  # flake by ~driver 20+. v0.12: log to file, grep file, use real
  # exit code.
  log="/tmp/os-e2e-${name}.log"
  if sbcl --no-userinit --no-sysinit --non-interactive \
          --load "$driver" > "$log" 2>&1 ; then
    rc=0
  else
    rc=$?
  fi
  grep -E "VERDICT|PHASE|xdotool|minibuffer|page " "$log" || true
  if [ $rc -eq 0 ]; then
    echo "  ✓ $name PASS"
    pass=$((pass + 1))
  else
    echo "  ✗ $name FAIL"
    fail=$((fail + 1))
    fails+=("$name")
  fi
done

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OS-LEVEL TOTAL: $pass passed, $fail failed"
[ $fail -eq 0 ] || printf '  Failed: %s\n' "${fails[@]}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $fail
