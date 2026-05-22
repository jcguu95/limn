#!/usr/bin/env bash
# run-repl.sh — start a limn subprocess + SBCL REPL connected to it.
#
# Defaults to headless (offscreen Qt) so you don't get a stray window.
# Pass HEADLESS=0 to get a visible Qt window for visual inspection.
#
# Examples:
#   ./backend/run-repl.sh                          # headless
#   HEADLESS=0 ./backend/run-repl.sh               # visible Qt window
#   LIMN_INITIAL=path/to.pdf ./backend/run-repl.sh # pre-open a file

set -e
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Use rlwrap if available — gives readline editing + history.
if command -v rlwrap >/dev/null 2>&1; then
  RUNNER=(rlwrap -c sbcl)
else
  RUNNER=(sbcl)
fi

# Inside `nix develop` if a flake exists and we're not already in the shell.
if [ -f flake.nix ] && [ -z "${IN_NIX_SHELL:-}" ]; then
  exec nix develop --command bash -c \
    "${RUNNER[*]} --load backend/repl.lisp"
else
  exec "${RUNNER[@]}" --load backend/repl.lisp
fi
