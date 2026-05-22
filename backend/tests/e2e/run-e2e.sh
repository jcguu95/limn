#!/usr/bin/env bash
# Run every e2e driver in backend/tests/e2e/, report pass/fail.
#
# Each driver:
#   - is a standalone .lisp file
#   - spawns its own limn binary and tears it down
#   - exits 0 on pass, non-zero on fail
#   - prints a VERDICT line we grep

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
E2E_DIR="$PROJECT_ROOT/backend/tests/e2e"

export LIMN_BACKEND_DIR="$PROJECT_ROOT/backend/"
export LIMN_BIN="${LIMN_BIN:-$PROJECT_ROOT/sioyek/limn.app/Contents/MacOS/limn}"
[ -x "$LIMN_BIN" ] || LIMN_BIN="$PROJECT_ROOT/sioyek/sioyek.app/Contents/MacOS/sioyek"

if [ ! -x "$LIMN_BIN" ]; then
  echo "✗ limn binary not found at $LIMN_BIN"
  exit 2
fi

pass=0
fail=0
fails=()

for driver in "$E2E_DIR"/batch*.lisp; do
  # Skip OS-level drivers — they require Xvfb + xdotool inside the
  # Linux container. Run via run-os-e2e.sh instead.
  case "$driver" in
    *batch-os-*.lisp) continue ;;
  esac
  name="$(basename "$driver" .lisp)"
  echo "── $name ─────────────────────────────────────"
  if sbcl --no-userinit --no-sysinit --non-interactive \
          --load "$driver" 2>&1 \
       | grep -E "VERDICT|PHASE|inject |minibuffer|loaded init" ; then
    :
  fi
  # Re-run to get exit code (the grep above was for visibility only)
  if sbcl --no-userinit --no-sysinit --non-interactive \
          --load "$driver" > /dev/null 2>&1 ; then
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
echo "  TOTAL: $pass passed, $fail failed"
[ $fail -eq 0 ] || printf '  Failed: %s\n' "${fails[@]}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $fail
