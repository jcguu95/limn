#!/usr/bin/env bash
# verify-logging-v037-visible.sh — v0.37 logging 視覺驗證 launcher
#
# 用法：
#   bash /Users/jin/data/local/projects/sioyek-core/.claude/worktrees/reverent-williams-90cb72/scripts/verify-logging-v037-visible.sh
#
# 跟 verify-logging-v037.sh 的差別：
#   verify-logging-v037.sh         → HEADLESS=1，只 auto-check 資料層、
#                                    不開 Qt 視窗、27 個 step
#   verify-logging-v037-visible.sh → HEADLESS=0，*打開 Qt 視窗*、把 *messages*
#                                    切到主 widget、fire 7 條 log、user *用眼睛*
#                                    確認真的有顯示 + auto-scroll
#
# 為什麼分兩個 launcher：
#   資料層驗證 (CI-friendly、機器可判斷) vs 視覺驗證 (人眼判斷、要 Qt)
#   是兩件事。混在一起會被 HEADLESS env 互相干擾。
#
# 為什麼這個 visible 版本必須用 worktree binary：
#   v0.37 logging A-path 的 C++ 修補（讓 *messages* 走 sync_text_widget 的
#   chrome-skip 邏輯放行 + cmd_message_log/echo 末尾呼叫 sync）只在 worktree
#   重 build 出來的 binary 才有。用 main tree 舊 binary 切過去主 widget
#   會是空白。

set -e

# ── 絕對路徑 ─────────────────────────────────────────────────────────
PROJECT_ROOT="/Users/jin/data/local/projects/sioyek-core/.claude/worktrees/reverent-williams-90cb72"
WORKTREE_BIN="${PROJECT_ROOT}/sioyek/limn.app/Contents/MacOS/limn"
BUILD_SCRIPT="${PROJECT_ROOT}/scripts/build-macos.sh"
VERIFY_LISP="${PROJECT_ROOT}/tmp/verify-logging-v037.lisp"
RUN_REPL_SH="${PROJECT_ROOT}/backend/run-repl.sh"

# ── (1) worktree binary 必備 ─────────────────────────────────────────
# 沒有就 build。不像 headless 版有 main-tree fallback —— 這裡 fallback
# 沒意義（main-tree binary 沒帶這 batch 的 C++ widget 修補）。
if [ ! -x "$WORKTREE_BIN" ]; then
  echo "→ worktree binary 不存在，幫你 build：${BUILD_SCRIPT}"
  bash "$BUILD_SCRIPT"
  if [ ! -x "$WORKTREE_BIN" ]; then
    echo "✗ build 完還是找不到 worktree binary：$WORKTREE_BIN"
    exit 1
  fi
fi

# ── (2) 檢查 verify lisp + run-repl.sh ───────────────────────────────
if [ ! -f "$VERIFY_LISP" ]; then
  echo "✗ 找不到驗證腳本：$VERIFY_LISP"; exit 1
fi
if [ ! -f "$RUN_REPL_SH" ]; then
  echo "✗ 找不到 REPL launcher：$RUN_REPL_SH"; exit 1
fi

echo "→ binary       ：$WORKTREE_BIN"
echo "→ verify 腳本  ：$VERIFY_LISP"
echo "→ 開 *visible* Qt 視窗（你應該看到一個視窗彈出來）⋯⋯"
echo

# ── (3) 啟動：HEADLESS=0、呼 run-visible ─────────────────────────────
# HEADLESS=0 是關鍵差別 —— Qt 視窗會真的顯示在螢幕上。
# 跟 headless 版一樣靠 run-repl.sh 起 sbcl + 連上 limn。
export LIMN_BIN="$WORKTREE_BIN"
export HEADLESS=0
cd "$PROJECT_ROOT"
exec bash "$RUN_REPL_SH" \
  --load "$VERIFY_LISP" \
  --eval '(verify-logging:run-visible)'
