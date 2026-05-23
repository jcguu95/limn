#!/usr/bin/env bash
# Run all three test tiers in sequence. Stops on first tier failure.
#
# Tiers:
#   unit         pure-Lisp, mock client, seconds
#   integration  real limn binary + raw JSON wire, ~30s
#   qt-e2e       real Lisp client + real limn binary, Qt-level inject, ~30s
#   os-e2e       (optional) Linux container, OS-level xdotool inject,
#                ~1m (~5-10m first time when building container)
#
# Usage:
#   bash backend/tests/run-all-tiers.sh           # all four tiers
#   bash backend/tests/run-all-tiers.sh --no-os   # skip os-e2e (faster)

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

SKIP_OS=0
for arg in "$@"; do
  case "$arg" in
    --no-os) SKIP_OS=1 ;;
    *) echo "Unknown arg: $arg"; exit 2 ;;
  esac
done

step() { printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  %s\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n' "$1"; }

step "1/4  unit tests"
sbcl --script backend/tests/unit/run-unit.lisp || {
  echo "✗ unit failed"; exit 1; }

step "2/4  integration tests"
HEADLESS=1 bash backend/tests/run-tests.sh || {
  echo "✗ integration failed"; exit 1; }

step "3/4  qt-level e2e"
bash backend/tests/e2e/run-e2e.sh || {
  echo "✗ qt-e2e failed"; exit 1; }

if [ $SKIP_OS -eq 1 ]; then
  echo
  echo "(skipped: os-e2e — pass without --no-os to include)"
  echo
  echo "✓ ALL TIERS PASS (--no-os)"
  exit 0
fi

step "4/4  os-level e2e (container)"

# Need docker daemon running.
if ! docker info > /dev/null 2>&1; then
  echo "✗ Docker daemon not running. Start Docker Desktop / Colima first."
  echo "  (Or pass --no-os to skip OS-level e2e.)"
  exit 1
fi

# Build image if missing or source changed since last build.
echo "→ building/refreshing limn-e2e image (uses layer cache)..."
docker build -q -t limn-e2e . || {
  echo "✗ docker build failed"; exit 1; }

echo "→ running OS-level e2e inside container..."
docker run --rm limn-e2e || {
  echo "✗ os-e2e failed"; exit 1; }

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ ALL TIERS PASS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
