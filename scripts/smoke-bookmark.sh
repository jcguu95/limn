#!/usr/bin/env bash
# v0.37 — "bookmark everywhere" smoke harness.
#
# Goal: <60 seconds from "run this" to "I've watched the feature work".
#
# What this does:
#   1. Builds a small text fixture at /tmp/limn-smoke-note.txt
#   2. Stashes the user's real ~/.limn/bookmarks.lisp (if any) and
#      writes a fresh sidecar with 3 pre-seeded bookmarks pointing at
#      the fixture PDF + the text file.
#   3. Optionally:
#      --headless   runs the OS-tier driver (no GUI, ~30s, full
#                   regression including persistence + handler dispatch
#                   + wire round-trips).  Best when you just want a
#                   pass/fail signal.
#      --visual     launches the real macOS Limn binary so you can
#                   try `C-x r b` / `C-x r m` interactively.  Default.
#   4. On exit (Ctrl-C or Limn quit): restores the original sidecar.
#
# Usage:
#   bash scripts/smoke-bookmark.sh                # interactive (default)
#   bash scripts/smoke-bookmark.sh --headless     # CI-style pass/fail
#   bash scripts/smoke-bookmark.sh --both         # both back-to-back

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# v0.37 directive 1: macOS testing always via nix.
if [ -f "$PROJECT_ROOT/flake.nix" ] && [ -z "${LIMN_NIX_SHELL:-}" ]; then
  exec nix develop "$PROJECT_ROOT" --command bash "$0" "$@"
fi

MODE="visual"
for arg in "$@"; do
  case "$arg" in
    --headless) MODE="headless" ;;
    --visual)   MODE="visual" ;;
    --both)     MODE="both" ;;
    -h|--help)
      sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $arg (try --help)"; exit 2 ;;
  esac
done

find_limn_bin() {
  # Caller-provided wins.
  [ -n "${LIMN_BIN:-}" ] && [ -x "$LIMN_BIN" ] && { echo "$LIMN_BIN"; return; }
  # Walk up: PROJECT_ROOT first (normal), then up to two parents
  # in case we're running from a worktree under .claude/worktrees/*.
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
FIXTURE_PDF="$PROJECT_ROOT/backend/tests/fixtures/test.pdf"
[ -f "$FIXTURE_PDF" ] || FIXTURE_PDF="$PROJECT_ROOT/../../../backend/tests/fixtures/test.pdf"
TXT_FIXTURE="/tmp/limn-smoke-note.txt"

SIDECAR="$HOME/.limn/bookmarks.lisp"
SIDECAR_STASH="$HOME/.limn/bookmarks.lisp.smoke-stash-$$"

# ── checks ──────────────────────────────────────────────────────────
[ -n "$LIMN_BIN" ] && [ -x "$LIMN_BIN" ] || {
  echo "✗ Limn binary not found.  Set LIMN_BIN or build via scripts/build-macos.sh"
  exit 1
}
[ -f "$FIXTURE_PDF" ] || {
  echo "✗ Missing fixture PDF — see backend/tests/fixtures/README.md"
  exit 1
}
echo "→ Using binary:  $LIMN_BIN"
echo "→ Using fixture: $FIXTURE_PDF"

# ── seed fixtures ───────────────────────────────────────────────────
cat > "$TXT_FIXTURE" <<EOF
line 1: hello bookmark everywhere
line 2: this is a smoke fixture
line 3: jump to me with C-x r b
line 4: end of fixture
EOF

mkdir -p "$HOME/.limn"
if [ -f "$SIDECAR" ]; then
  cp -p "$SIDECAR" "$SIDECAR_STASH"
  echo "→ stashed existing $SIDECAR → $(basename "$SIDECAR_STASH")"
fi

# Sidecar shape mirrors what bookmarks-save writes: (:version 1
# :bookmarks (PLIST ...)).  Handlers must intern in :cl-user namespace
# because that's where text-mode / pdf-mode symbols live.
cat > "$SIDECAR" <<EOF
(:version 1
 :bookmarks
 ((:name "smoke-pdf-p1"
   :handler cl-user::pdf-mode
   :record (:path "$FIXTURE_PDF"
            :page 0 :y-offset 0.0 :x-offset 0.0))
  (:name "smoke-pdf-p3"
   :handler cl-user::pdf-mode
   :record (:path "$FIXTURE_PDF"
            :page 2 :y-offset 0.0 :x-offset 0.0))
  (:name "smoke-txt-note"
   :handler cl-user::text-mode
   :record (:file "$TXT_FIXTURE"
            :position 35))))
EOF
echo "→ seeded $SIDECAR with 3 sample bookmarks"

# ── cleanup hook ────────────────────────────────────────────────────
restore() {
  if [ -f "$SIDECAR_STASH" ]; then
    mv -f "$SIDECAR_STASH" "$SIDECAR"
    echo "→ restored your original bookmarks.lisp"
  else
    rm -f "$SIDECAR"
    echo "→ removed smoke sidecar (you had none originally)"
  fi
  rm -f "$TXT_FIXTURE"
}
trap restore EXIT INT TERM

# ── run ──────────────────────────────────────────────────────────────
run_headless() {
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  headless: spawning Limn + driving via wire"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  LIMN_BIN="$LIMN_BIN" \
  LIMN_FIXTURE="$FIXTURE_PDF" \
  LIMN_BACKEND_DIR="$PROJECT_ROOT/backend/" \
    sbcl --no-userinit --no-sysinit --non-interactive \
         --load "$PROJECT_ROOT/backend/tests/e2e/batch-os-v037-bookmark.lisp"
  return $?
}

run_visual() {
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  visual: launching Limn — try the bookmarks"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  echo "  Try, in order:"
  echo "    1. M-x bookmark-list  (or C-x r l) → echo area shows 3"
  echo "    2. C-x r b smoke-pdf-p3 RET        → jumps to page 3"
  echo "    3. C-x r b smoke-txt-note RET      → opens the txt at pos 35"
  echo "    4. C-x r m my-spot RET             → set a new bookmark"
  echo
  echo "  When you're done: quit Limn (or Ctrl-C this script)."
  echo
  "$LIMN_BIN" "$FIXTURE_PDF"
}

case "$MODE" in
  headless) run_headless; STATUS=$? ;;
  visual)   run_visual;   STATUS=$? ;;
  both)
    run_headless || { echo "✗ headless failed"; exit 1; }
    echo; echo "→ headless PASS; continuing to visual…"; sleep 1
    run_visual; STATUS=$?
    ;;
esac

exit "$STATUS"
