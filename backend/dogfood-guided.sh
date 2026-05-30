#!/usr/bin/env bash
# dogfood-guided.sh — 互動式視窗分割驗收（Phase 3b）。
#
# 一鍵啟動可見 Qt、自動開檔＋分割，然後逐項：
#   1. 自動「註入」要 eval 的 form（開檔/分割/移焦點/注入按鍵…）
#   2. 印出「你現在應該在 Qt 視窗看到什麼」
#   3. 你按 y（確定通過）/ n（不確定）/ s（略過）/ q（中止），Enter
#   4. 最後印出一段 markdown 摘要，直接複製貼上即可
#
# 用法：
#   ./backend/dogfood-guided.sh                  # tutorial.pdf，左右分割
#   ./backend/dogfood-guided.sh /path/to.pdf     # 指定 PDF
#   ./backend/dogfood-guided.sh /path/to.pdf v   # 上下分割
#
# 對照清單：backend/SPLIT-DOGFOOD-CHECKLIST.md

set -e
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

PDF="${1:-$PROJECT_ROOT/sioyek/tutorial.pdf}"
DIR="${2:-h}"

if [ ! -f "$PDF" ]; then
  echo "✗ 找不到 PDF：$PDF" >&2
  exit 1
fi
if [ "$DIR" != "h" ] && [ "$DIR" != "v" ]; then
  echo "✗ 分割方向只能是 'h'（左右）或 'v'（上下），收到：$DIR" >&2
  exit 1
fi

echo "→ 互動式驗收：開可見 Qt、自動開檔＋分割，逐項問你 y/n。"
echo "→ PDF：$PDF  分割：$DIR"
echo

# HEADLESS=0 → 可見 Qt。先 --load 驅動器（定義 dogfood），再 --eval 跑它。
# run-repl.sh 會把這些參數轉發給 sbcl（helpers 已在 repl.lisp 載好）。
#
# LIMN_BIN：明確 pin 到「這個 worktree 剛 build 的 binary」。不 pin 的話會走
# repl.lisp 的 default-limn-bin（相對 CWD 推算 ../sioyek/limn.app），在多 worktree
# /多 session 的機器上有機率解析到別的 checkout 的舊 binary（沒有 Phase 3b 分割），
# 跑起來就「不分割」——這正是 dogfood 卡在第 1 項的真兇。
#
# LIMN_TITLE：把這個視窗的標題加上獨一無二的字尾，避免和其他平行 session
# （別的 git worktree 同時開的 limn 視窗，標題同樣是 "limn"）搞混。跑起來後
# 在螢幕上找標題寫「limn — PH3-SPLIT DOGFOOD」的那個視窗，才是這支腳本開的。
LIMN_BIN_PINNED="$PROJECT_ROOT/sioyek/limn.app/Contents/MacOS/limn"
if [ ! -x "$LIMN_BIN_PINNED" ]; then
  echo "✗ 找不到剛 build 的 limn binary：$LIMN_BIN_PINNED" >&2
  echo "  先在 $PROJECT_ROOT/sioyek 跑 make 再來。" >&2
  exit 1
fi
echo "→ 用 binary：$LIMN_BIN_PINNED"
exec env HEADLESS=0 LIMN_TITLE="PH3-SPLIT DOGFOOD" \
  LIMN_BIN="$LIMN_BIN_PINNED" \
  "$PROJECT_ROOT/backend/run-repl.sh" \
  --load "$PROJECT_ROOT/backend/dogfood-guided.lisp" \
  --eval "(dogfood \"$PDF\" \"$DIR\")"
