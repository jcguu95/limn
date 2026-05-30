#!/usr/bin/env bash
# verify-logging-v037.sh — v0.37 logging 自動驗證 launcher
#
# 用法：
#   bash /Users/jin/data/local/projects/sioyek-core/.claude/worktrees/reverent-williams-90cb72/scripts/verify-logging-v037.sh
#
# 做什麼：
#   1. 檢查 Limn binary 在不在；不在的話幫你跑 build-macos.sh build 出來
#   2. 起 run-repl.sh（會 spawn 一個 headless Limn binary、開 SBCL REPL、
#      自動 (limn:start ...) 連上去）
#   3. 預載 tmp/verify-logging-v037.lisp（定義 verify-logging package）
#   4. 自動呼叫 (verify-logging:run) 開始逐 step 驗證
#   5. 結束後丟你回 SBCL REPL 提示符。打 (sb-ext:exit) 離開
#
# 互動鍵：
#   ENTER       下一步
#   q + ENTER   中止、印 summary
#   s + ENTER   跳過這 step（標 SKIP）、繼續
#
# 為什麼分兩個檔：
#   .lisp 檔負責 step 定義跟 runner 邏輯（純 Lisp、純資料）；
#   .sh 檔負責環境（找 binary、build、起 REPL）。
#   分開的話 Lisp 那邊只要關心驗證邏輯、Shell 這邊只要關心起 sbcl。

set -e

# ── 絕對路徑（worktree-aware，不依賴 cwd） ────────────────────────────
PROJECT_ROOT="/Users/jin/data/local/projects/sioyek-core/.claude/worktrees/reverent-williams-90cb72"
MAIN_TREE="/Users/jin/data/local/projects/sioyek-core"
# v0.37 logging A-path：C++ 改動在 worktree，必須優先用 worktree binary。
# main tree 那份只當 fallback（沒有 *messages* widget rendering 修補）。
WORKTREE_BIN="${PROJECT_ROOT}/sioyek/limn.app/Contents/MacOS/limn"
MAIN_BIN_PRIMARY="${MAIN_TREE}/sioyek/limn.app/Contents/MacOS/limn"
MAIN_BIN_FALLBACK="${MAIN_TREE}/sioyek/sioyek.app/Contents/MacOS/sioyek"
BUILD_SCRIPT="${PROJECT_ROOT}/scripts/build-macos.sh"
VERIFY_LISP="${PROJECT_ROOT}/tmp/verify-logging-v037.lisp"
RUN_REPL_SH="${PROJECT_ROOT}/backend/run-repl.sh"

# ── (1) 找 binary。優先級：worktree > main tree limn > main tree sioyek ─
# 為什麼這個順序：
#   1. 本 batch 的 C++ 修補（*messages* 在主 widget 顯示）只在 worktree
#      編出來的 binary 才有；用 main tree binary 雖然能跑、但 *messages*
#      切過去仍是空白。
#   2. main tree limn.app fallback：歷史 dogfood binary、無此 batch 修補
#      但其餘功能完整。
#   3. main tree sioyek.app：v0.27 之前的舊命名、最後 fallback。
LIMN_BIN=""
if [ -x "$WORKTREE_BIN" ]; then
  LIMN_BIN="$WORKTREE_BIN"
elif [ -x "$MAIN_BIN_PRIMARY" ]; then
  LIMN_BIN="$MAIN_BIN_PRIMARY"
  echo "⚠  用 main tree binary（無 v0.37 *messages* widget 修補）"
  echo "    要看到 *messages* 在 Qt 視窗、跑 $BUILD_SCRIPT build worktree 版本"
elif [ -x "$MAIN_BIN_FALLBACK" ]; then
  LIMN_BIN="$MAIN_BIN_FALLBACK"
  echo "⚠  用 main tree sioyek.app fallback（極舊版本）"
else
  echo "→ 找不到任何 Limn binary，幫你 build worktree 版本：${BUILD_SCRIPT}"
  bash "$BUILD_SCRIPT"
  if [ -x "$WORKTREE_BIN" ]; then
    LIMN_BIN="$WORKTREE_BIN"
  else
    echo "✗ build 完還是找不到 worktree binary：$WORKTREE_BIN"
    echo "  請手動跑 $BUILD_SCRIPT 看哪邊壞掉。"
    exit 1
  fi
fi

# ── (2) 檢查 verify 腳本存在 ──────────────────────────────────────────
if [ ! -f "$VERIFY_LISP" ]; then
  echo "✗ 找不到驗證腳本：$VERIFY_LISP"
  echo "  這檔應該跟本 script 一起 ship，可能被誤刪。"
  exit 1
fi

# ── (3) 檢查 run-repl.sh 存在 ─────────────────────────────────────────
if [ ! -f "$RUN_REPL_SH" ]; then
  echo "✗ 找不到 REPL launcher：$RUN_REPL_SH"
  exit 1
fi

echo "→ binary       ：$LIMN_BIN"
echo "→ verify 腳本  ：$VERIFY_LISP"
echo "→ 開 REPL（headless）⋯⋯"
echo

# ── (4) 移交給 run-repl.sh ────────────────────────────────────────────
# run-repl.sh 會：
#   - 先 --load backend/repl.lisp（裡面 (limn:start ...) 連上 binary）
#   - 然後把我們傳的 extra 參數轉給 sbcl
# 所以順序是：
#   sbcl --load repl.lisp        ← limn 起來、session 連上
#        --load $VERIFY_LISP     ← 定義 verify-logging package
#        --eval '(verify-logging:run)'  ← 開跑
#
# HEADLESS=1 是給 binary 看的（offscreen Qt、不要彈視窗）。
# LIMN_BIN 是給 run-repl.sh 看的（用哪份 binary）。
export LIMN_BIN
export HEADLESS=1
cd "$PROJECT_ROOT"
exec bash "$RUN_REPL_SH" \
  --load "$VERIFY_LISP" \
  --eval '(verify-logging:run)'
