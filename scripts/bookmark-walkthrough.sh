#!/usr/bin/env bash
# v0.37 bookmark-everywhere — interactive walkthrough launcher.
#
# Single command from "I want to test" to "I'm pressing y/n on each
# injected form".  Handles:
#
#   1. Wrapping in nix develop (auto)
#   2. Bumping ulimit -n to 8192 (auto)
#   3. Finding the Limn binary (tries current worktree + parent project)
#   4. Building it if missing (runs scripts/build-macos.sh, ~5 min once)
#   5. Locating the fixture PDF
#   6. Launching the walkthrough Lisp script
#
# Usage:
#   bash scripts/bookmark-walkthrough.sh
#   LIMN_BIN=/path/to/limn bash scripts/bookmark-walkthrough.sh   # override

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── nix wrap (v0.37 directive 1) ────────────────────────────────────
if [ -f "$PROJECT_ROOT/flake.nix" ] && [ -z "${LIMN_NIX_SHELL:-}" ]; then
  exec nix develop "$PROJECT_ROOT" --command bash "$0" "$@"
fi

# ── ulimit ──────────────────────────────────────────────────────────
ulimit -n 8192 2>/dev/null || true

# ── locate Limn binary (worktree, parent project, container) ───────
find_limn_bin() {
  [ -n "${LIMN_BIN:-}" ] && [ -x "$LIMN_BIN" ] && { echo "$LIMN_BIN"; return; }
  local candidates=(
    "$PROJECT_ROOT/sioyek/limn.app/Contents/MacOS/limn"
    "$PROJECT_ROOT/sioyek/sioyek.app/Contents/MacOS/sioyek"
    "$PROJECT_ROOT/../../../sioyek/limn.app/Contents/MacOS/limn"
    "$PROJECT_ROOT/../../../sioyek/sioyek.app/Contents/MacOS/sioyek"
    "/limn/sioyek/limn"
  )
  for c in "${candidates[@]}"; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  echo ""
}

LIMN_BIN="$(find_limn_bin)"

# ── build if missing ────────────────────────────────────────────────
if [ -z "$LIMN_BIN" ]; then
  echo "→ Limn binary not found anywhere.  Building (~5 min, one time)…"
  build_script="$PROJECT_ROOT/scripts/build-macos.sh"
  [ -f "$build_script" ] || build_script="$PROJECT_ROOT/../../../scripts/build-macos.sh"
  if [ ! -f "$build_script" ]; then
    echo "✗ scripts/build-macos.sh not found.  Run nix build or build by hand."
    exit 1
  fi
  bash "$build_script" || { echo "✗ build failed"; exit 1; }
  LIMN_BIN="$(find_limn_bin)"
fi

[ -n "$LIMN_BIN" ] && [ -x "$LIMN_BIN" ] || {
  echo "✗ Limn binary still missing after build attempt"
  exit 1
}

# ── locate fixture ──────────────────────────────────────────────────
FIXTURE_PDF="$PROJECT_ROOT/backend/tests/fixtures/test.pdf"
[ -f "$FIXTURE_PDF" ] || FIXTURE_PDF="$PROJECT_ROOT/../../../backend/tests/fixtures/test.pdf"

[ -f "$FIXTURE_PDF" ] || {
  echo "✗ Missing test.pdf — see backend/tests/fixtures/README.md"
  exit 1
}

# ── launch ──────────────────────────────────────────────────────────
echo "  using binary:  $LIMN_BIN"
echo "  using fixture: $FIXTURE_PDF"
echo

exec env \
  LIMN_BIN="$LIMN_BIN" \
  LIMN_FIXTURE="$FIXTURE_PDF" \
  LIMN_BACKEND_DIR="$PROJECT_ROOT/backend/" \
  sbcl --no-userinit --no-sysinit \
       --load "$PROJECT_ROOT/scripts/bookmark-walkthrough.lisp"
