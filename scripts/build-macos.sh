#!/usr/bin/env bash
# build-macos.sh — canonical way to build the Limn binary on macOS host.
#
# Pair with scripts/build-docker.sh.  Forces a clean rebuild because
# the build-provenance DEFINES (git hash / build time) are baked into
# .o files at compile time; if .cpp mtimes are unchanged, make would
# skip recompilation and the resulting binary would link with .o files
# containing STALE DEFINES — current source but old --version output.
#
# Usage:  bash scripts/build-macos.sh
#         (prints --version banner on success so you can verify the
#          binary stamps the current HEAD)

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIOYEK_DIR="$REPO_ROOT/sioyek"

if [ ! -f "$REPO_ROOT/flake.nix" ]; then
  echo "✗ no flake.nix at $REPO_ROOT — not a Limn checkout"
  exit 1
fi

cd "$SIOYEK_DIR"

echo "── cleaning prior build artifacts ──"
rm -f .qmake.stash Makefile
rm -f *.o pdf_viewer/*.o
rm -f moc_*.cpp moc_predefs.h qrc_resources.cpp
rm -rf limn.app

echo "── rebuilding via nix develop ──"
nix develop "$REPO_ROOT" --command bash -c '
  qmake pdf_viewer_build_config.pro && \
  make -j$(sysctl -n hw.ncpu)
'

BINARY="$SIOYEK_DIR/limn.app/Contents/MacOS/limn"
if [ ! -x "$BINARY" ]; then
  echo "✗ build finished but binary not at $BINARY"
  exit 2
fi

echo
echo "── binary --version ──"
"$BINARY" --version

EXPECTED="$(cd "$REPO_ROOT" && git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
REPORTED="$("$BINARY" --version 2>&1 | grep 'git:' | awk '{print $2}')"

echo
if [ "$EXPECTED" = "$REPORTED" ]; then
  echo "✓ git hash matches HEAD ($EXPECTED)"
else
  echo "⚠ git hash mismatch: HEAD=$EXPECTED, binary=$REPORTED"
  exit 3
fi
