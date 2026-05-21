#!/usr/bin/env bash
# Run the Limn test suite.
#
# This script:
#   1. Starts Limn in headless mode listening on a test socket.
#   2. Waits for the socket to appear.
#   3. Runs SBCL with run-all.lisp.
#   4. Kills Limn at the end.
#
# Expects Limn to support:
#   limn --headless --socket /tmp/limn-test

set -e
set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOCKET="${LIMN_SOCKET:-/tmp/limn-test-$$}"
LIMN_BIN="${LIMN_BIN:-$PROJECT_ROOT/sioyek/sioyek.app/Contents/MacOS/sioyek}"
FIXTURE_DIR="$PROJECT_ROOT/backend/tests/fixtures"
LOG="/tmp/limn-test.log"

# 1. fixture present?
if [ ! -f "$FIXTURE_DIR/test.pdf" ]; then
  echo "✗ Missing test fixture: $FIXTURE_DIR/test.pdf"
  echo "  See $FIXTURE_DIR/README.md for instructions."
  exit 2
fi

# 2. clean up any stale socket
rm -f "$SOCKET"

# 3. start Limn headless in background
echo "→ Starting Limn (socket=$SOCKET)"
"$LIMN_BIN" --headless --socket "$SOCKET" > "$LOG" 2>&1 &
LIMN_PID=$!

cleanup() {
  echo "→ Killing Limn (pid=$LIMN_PID)"
  kill "$LIMN_PID" 2>/dev/null || true
  wait "$LIMN_PID" 2>/dev/null || true
  rm -f "$SOCKET"
}
trap cleanup EXIT

# 4. wait for socket
echo -n "→ Waiting for socket"
for i in $(seq 1 50); do
  if [ -S "$SOCKET" ]; then
    echo " — ready."
    break
  fi
  echo -n "."
  sleep 0.1
done

if [ ! -S "$SOCKET" ]; then
  echo
  echo "✗ Limn did not create socket within 5s."
  echo "  See log: $LOG"
  cat "$LOG"
  exit 3
fi

# 5. run tests
echo "→ Running tests"
export LIMN_SOCKET="$SOCKET"
export LIMN_FIXTURE="$FIXTURE_DIR/test.pdf"

cd "$PROJECT_ROOT"
sbcl --script backend/tests/run-all.lisp
TEST_EXIT=$?

exit $TEST_EXIT
