#!/usr/bin/env bash
# run-repl.sh — start a limn subprocess + SBCL REPL connected to it.
#
# Defaults to headless (offscreen Qt) so you don't get a stray window.
# Pass HEADLESS=0 to get a visible Qt window for visual inspection.
#
# Examples:
#   ./backend/run-repl.sh             # headless
#   HEADLESS=0 ./backend/run-repl.sh  # visible Qt window
#
# Any extra args are forwarded to sbcl AFTER --load backend/repl.lisp
# (so they run with limn already up and helpers like (o ...) defined).
# Useful for one-shot automation:
#
#   HEADLESS=0 ./backend/run-repl.sh --eval '(o "/tmp/m.pdf")'
#     → launches visible Qt, opens /tmp/m.pdf, drops to SBCL prompt
#
#   ./backend/run-repl.sh --eval '(o "/tmp/m.pdf")' --eval '(q)'
#     → headless one-shot: open, then quit cleanly
#
# To open a PDF interactively: type (o "/path/to.pdf") at the REPL prompt.
# (The old LIMN_INITIAL env var was removed in v0.39 — it took the
# legacy MainWidget::open_document path instead of cmd_buffer_open,
# which meant pdf-mode was never installed and j/k did nothing.)

set -e
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# --help: print the header comment block and exit.
case "${1:-}" in
  -h|--help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

# Use rlwrap if available — gives readline editing + history.
if command -v rlwrap >/dev/null 2>&1; then
  RUNNER=(rlwrap -c sbcl)
else
  RUNNER=(sbcl)
fi

# Forward any extra args to sbcl, AFTER --load backend/repl.lisp, so forms
# like --eval '(o "/tmp/m.pdf")' run with limn live and (o ...) defined.
# SBCL processes --load/--eval in argv order, so position matters here.
# printf '%q' produces a shell-safe quoting that survives the extra
# `bash -c "..."` layer used by the nix-develop path.
SBCL_EXTRA=""
for arg in "$@"; do
  SBCL_EXTRA+=" $(printf '%q' "$arg")"
done

# Inside `nix develop` if a flake exists and we're not already in the shell.
if [ -f flake.nix ] && [ -z "${IN_NIX_SHELL:-}" ]; then
  exec nix develop --command bash -c \
    "${RUNNER[*]} --load backend/repl.lisp${SBCL_EXTRA}"
else
  # Non-nix path: keep "${RUNNER[@]}" un-shell-eval'd, append raw args.
  exec "${RUNNER[@]}" --load backend/repl.lisp "$@"
fi
