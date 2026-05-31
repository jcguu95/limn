#!/usr/bin/env bash
#
# Fuzzy Selector §3–§6 互動式視覺驗證腳本
#
# 用法：
#   bash /Users/jin/data/local/projects/limn-minad/scratch/run-fuzzy-walkthrough.sh
#
# 說明：
#   §A（STEP 1–6）：Lisp 行為確認，只需 SBCL，用 main-repo binary 就夠。
#   §B（STEP 7–11）：Qt 視覺確認，最好用 workspace 重 build 的 binary。
#                   若用 main-repo binary，§B 候選渲染步驟請按 s 跳過。
#
# 操作方式：
#   RET = PASS | n = FAIL | c = 留備注再 PASS | s = 跳過 | q = 離開

set -u

WORKSPACE=/Users/jin/data/local/projects/limn-minad
MAIN_REPO=/Users/jin/data/local/projects/sioyek-core
PDF="$WORKSPACE/sioyek/tutorial.pdf"

# ── 選擇 binary ──────────────────────────────────────────────────────────

WORKSPACE_BIN="$WORKSPACE/sioyek/limn.app/Contents/MacOS/limn"
MAIN_BIN="$MAIN_REPO/sioyek/limn.app/Contents/MacOS/limn"

if [ -x "$WORKSPACE_BIN" ]; then
  LIMN_BIN="$WORKSPACE_BIN"
  BIN_NOTE="✓ 使用 workspace binary（Qt §3/§4 修改已編譯）"
elif [ -x "$MAIN_BIN" ]; then
  LIMN_BIN="$MAIN_BIN"
  BIN_NOTE="⚠  使用 main-repo binary（Qt §3/§4 修改尚未編譯）
     §B 候選渲染步驟可能無效果，那些步驟請按 s 跳過。
     如需完整測試，先 build workspace：
       cd $WORKSPACE && nix develop --command bash scripts/build-macos.sh"
else
  echo "✗ 找不到任何 limn binary。"
  echo "  請先 build：cd $WORKSPACE && nix develop --command bash scripts/build-macos.sh"
  exit 2
fi

if [ ! -f "$PDF" ]; then
  echo "✗ tutorial.pdf 不見：$PDF"
  exit 3
fi

export LIMN_BIN
export HEADLESS=0

cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Fuzzy Selector §3–§6 — 互動式視覺驗證
  branch: deepseek/fuzzy-selector-ui
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Binary：$LIMN_BIN
  狀態：$BIN_NOTE

接下來會發生：
  1. SBCL 啟動、載入 workspace 的 limn 系統
  2. 開啟 Qt 視窗 + tutorial.pdf
  3. §A：Lisp 行為驗證（6 步，純後端）
  4. §B：Qt 視覺驗證（5 步，需在 Qt 視窗操作）
  5. 顯示最終通過 / 失敗報告

建議：把 terminal 跟 Qt 視窗並排，方便兩邊切換。

EOF

echo -n "按 RET 開始 / q+RET 取消："
read ans
[ "$ans" = "q" ] || [ "$ans" = "Q" ] && exit 0

# ── 啟動 SBCL + limn ─────────────────────────────────────────────────────

cd "$WORKSPACE"

# run-repl.sh 處理所有 SBCL + nix 啟動細節，跟 ibuffer walkthrough 完全一致
exec bash "$WORKSPACE/backend/run-repl.sh" \
  --eval "(o \"$PDF\")" \
  --load "$WORKSPACE/scratch/fuzzy-walkthrough.lisp"
