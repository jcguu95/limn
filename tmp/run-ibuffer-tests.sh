#!/usr/bin/env bash
#
# 一鍵跑 ibuffer mode 驗收：
#   1. 跑 unit suite（auto），印 summary
#   2. 進 SBCL REPL，逐步注入 form、auto-check 或問你一鍵確認
#   3. 結束印 REPORT，整段複製回 Claude
#
# 用法：
#   bash /Users/jin/data/local/projects/sioyek-core/.claude/worktrees/mystifying-dijkstra-2400c3/tmp/run-ibuffer-tests.sh

set -u

REPO=/Users/jin/data/local/projects/sioyek-core/.claude/worktrees/mystifying-dijkstra-2400c3
cd "$REPO"

UNIT_LOG=/tmp/ibuffer-unit-$$.log

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Phase 1/2 — Unit suite (自動跑、~10 秒)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

nix develop "$REPO" --command sbcl --script "$REPO/backend/tests/unit/run-unit.lisp" > "$UNIT_LOG" 2>&1
UNIT_EXIT=$?

echo "  exit code:    $UNIT_EXIT"
echo -n "  全體統計:     "
grep -E "[0-9]+ passed, [0-9]+ failed" "$UNIT_LOG" | tail -1
echo
echo "  Ibuffer 各 test (應該全部 0 failed)："

awk '/┌─ IBUFFER-/{name=$0; getline; while ($0 !~ /└─/){getline}; print "    " name "  " $0}' "$UNIT_LOG"

echo
echo "  完整 log:     $UNIT_LOG"

if [ "$UNIT_EXIT" -ne 0 ]; then
  echo
  echo "  ⚠️  unit suite 非零 exit。若 Failures 區塊只有以下 5 個就 OK："
  echo "     INIT-LOAD-RETURNS-NIL-WHEN-NONE-FOUND"
  echo "     V027-B-PDF-SEARCH-EXECUTE-STORES-STATE"
  echo "     V027-B-SEARCH-RESET-CLEARS-STATE"
  echo "     V027-I-SEARCH-STATE-CLEARED-ON-BUFFER-CLOSE"
  echo "     V027-I-SEARCH-STATE-ISOLATED-PER-BUFFER"
  echo "  否則表示 ibuffer 本身或我動到的東西打破了什麼。"
  echo "  按 RET 仍繼續下一階段，或 Ctrl-C 終止。"
  read -r _
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Phase 2/2 — Interactive sanity walk"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "  按 RET 開始（或 q+RET 直接離開）："
read -r START
case "$START" in
  q|Q) exit 0 ;;
esac

exec nix develop "$REPO" --command sbcl \
  --disable-debugger \
  --load "$REPO/tmp/ibuffer-test-driver.lisp"
