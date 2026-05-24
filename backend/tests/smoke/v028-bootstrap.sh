#!/usr/bin/env bash
# v028-bootstrap.sh — smoke test: 全模組載入後 sbcl 乾淨退出
#
# 測試 v0.29 的核心保證：
#   1. LIMN_NO_SPAWN=1 下 sbcl --script backend/repl.lisp 不爆任何 error
#   2. exit code = 0
#   3. stderr 無 "WARNING: redefin" 字樣（不重複定義任何函數 / 變數）
#
# 前提：v0.29 實作後 repl.lisp 包含以下 spawn guard：
#   (unless (string= (or (sb-ext:posix-getenv "LIMN_NO_SPAWN") "") "")
#     (spawn-limn) (limn:start ...) ...)
# 若 guard 未加，本 script 會因找不到 Qt binary 而 exit 非 0。
#
# 使用方法：
#   cd <repo-root>
#   bash backend/tests/smoke/v028-bootstrap.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REPL="$REPO/backend/repl.lisp"
LOG=$(mktemp /tmp/limn-bootstrap-XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

echo "→ smoke: LIMN_NO_SPAWN=1 sbcl --script backend/repl.lisp"
echo "  repo root : $REPO"
echo "  log       : $LOG"

# Run sbcl; capture both stdout and stderr to the log.
# --noinform suppresses the SBCL banner (cuts noise from the WARNING grep below).
LIMN_NO_SPAWN=1 \
  sbcl --noinform --script "$REPL" \
  >"$LOG" 2>&1
EXIT_CODE=$?

# ── Check 1: exit code ────────────────────────────────────────────────────
if [ "$EXIT_CODE" -ne 0 ]; then
  echo "✗ FAIL: sbcl exited with code $EXIT_CODE"
  echo "--- last 30 lines of log ---"
  tail -30 "$LOG"
  exit 1
fi
echo "✓ exit code 0"

# ── Check 2: no unhandled error messages ─────────────────────────────────
# SBCL prints "debugger invoked on ..." or "Unhandled ... condition" for
# runtime errors that aren't caught.
if grep -qiE "debugger invoked|unhandled .* condition|Error: " "$LOG"; then
  echo "✗ FAIL: unhandled error / debugger output found"
  echo "--- matching lines ---"
  grep -iE "debugger invoked|unhandled .* condition|Error: " "$LOG" | head -20
  exit 1
fi
echo "✓ no unhandled errors"

# ── Check 3: no redefinition warnings ────────────────────────────────────
# A "WARNING: redefining" line means a function or package is being loaded
# twice.  This indicates a load-order or duplicate-inclusion bug.
if grep -qiE "WARNING:.*redefin" "$LOG"; then
  echo "✗ FAIL: redefinition warnings found (possible duplicate load)"
  echo "--- matching lines ---"
  grep -iE "WARNING:.*redefin" "$LOG" | head -20
  exit 1
fi
echo "✓ no redefinition warnings"

echo ""
echo "✓ v028-bootstrap smoke PASSED"
