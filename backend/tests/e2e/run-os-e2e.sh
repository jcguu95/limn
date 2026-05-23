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
# UTF-8 locale required for xdotool to type CJK / multi-byte input.
# Without this, xdotool errors "Invalid multi-byte sequence" on non-ASCII.
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

pass=0
fail=0
fails=()

cleanup_between_drivers() {
  # Kill any limn process the previous driver may have left running.
  # 30+ drivers × multi sessions each = lots of opportunity for orphans.
  pkill -9 -f "/limn/sioyek/limn" 2>/dev/null || true
  # Remove stale socket files
  rm -f /tmp/limn-e2e-*-* /tmp/limn-real-* /tmp/limn-repl-* 2>/dev/null || true
  # Force-release any modifier keys that might be stuck
  xdotool keyup ctrl alt shift Meta_L 2>/dev/null || true

  # v0.14: forcibly destroy any residual X windows whose name contains
  # "Limn". Cumulative-state flake observed across mouse-extras + others
  # at ~25% rate (v0.13 noted as residual). Root cause: when a driver's
  # SIGKILL of Limn beats openbox's normal close handshake, the window
  # lingers in X tree for ~hundreds of ms; the next driver's
  # wait-for-window-by-name picks up the corpse, routes xdotool keys to
  # nowhere. Solution: actively xdotool windowkill them all and poll
  # until "search Limn" returns empty.
  for wid in $(xdotool search --name "Limn" 2>/dev/null); do
    xdotool windowkill "$wid" 2>/dev/null || true
  done
  # Poll up to 2s for windows to be fully gone before returning.
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [ -z "$(xdotool search --name 'Limn' 2>/dev/null)" ]; then
      break
    fi
    sleep 0.1
  done

  sleep 0.4
}

run_one_driver() {
  local driver="$1"
  local name="$(basename "$driver" .lisp)"
  local log="/tmp/os-e2e-${name}.log"
  if sbcl --no-userinit --no-sysinit --non-interactive \
          --load "$driver" > "$log" 2>&1 ; then
    return 0
  else
    return $?
  fi
}

for driver in "$E2E_DIR"/batch-os-*.lisp; do
  [ -f "$driver" ] || continue
  name="$(basename "$driver" .lisp)"
  echo "── $name ─────────────────────────────────────"
  cleanup_between_drivers
  log="/tmp/os-e2e-${name}.log"

  # First attempt
  if run_one_driver "$driver"; then
    grep -E "VERDICT|PHASE|xdotool|minibuffer|page " "$log" || true
    echo "  ✓ $name PASS"
    pass=$((pass + 1))
  else
    # Retry ONCE — Xvfb cumulative state pollution causes intermittent
    # flake (~10% per driver after ~15 prior drivers in same container).
    # Single retry with cleanup almost always passes if it's the flake.
    echo "  (first attempt failed, retrying once)"
    cleanup_between_drivers
    if run_one_driver "$driver"; then
      grep -E "VERDICT|PHASE|xdotool|minibuffer|page " "$log" || true
      echo "  ✓ $name PASS (retry)"
      pass=$((pass + 1))
    else
      grep -E "VERDICT|PHASE|xdotool|minibuffer|page " "$log" || true
      echo "  ✗ $name FAIL (failed twice)"
      fail=$((fail + 1))
      fails+=("$name")
    fi
  fi
done

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OS-LEVEL TOTAL: $pass passed, $fail failed"
[ $fail -eq 0 ] || printf '  Failed: %s\n' "${fails[@]}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $fail
