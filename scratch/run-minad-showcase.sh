#!/usr/bin/env bash
#
# MINAD 補全生態系 完整 showcase
#
# 用法：
#   bash /Users/jin/data/local/projects/limn-minad/scratch/run-minad-showcase.sh
#
# 幕 1–3 在真 Qt 視窗裡跑真實 completing-read session（腳本自動模擬使用者）。
# 幕 4 印出 Corfu/Cape 的真實後端計算。
# 每幕問你 PASS/FAIL。

set -u

WORKSPACE=/Users/jin/data/local/projects/limn-minad
MAIN_REPO=/Users/jin/data/local/projects/sioyek-core
PDF="$WORKSPACE/sioyek/tutorial.pdf"

WORKSPACE_BIN="$WORKSPACE/sioyek/limn.app/Contents/MacOS/limn"
MAIN_BIN="$MAIN_REPO/sioyek/limn.app/Contents/MacOS/limn"

if [ -x "$WORKSPACE_BIN" ]; then
  LIMN_BIN="$WORKSPACE_BIN"
  BIN_NOTE="✓ workspace binary（含 minibuffer/set-candidates 渲染）"
elif [ -x "$MAIN_BIN" ]; then
  LIMN_BIN="$MAIN_BIN"
  BIN_NOTE="⚠ main-repo binary（候選清單可能不會渲染，建議先 build workspace）"
else
  echo "✗ 找不到 limn binary。先 build：cd $WORKSPACE && nix develop --command bash scripts/build-macos.sh"
  exit 2
fi

if [ ! -f "$PDF" ]; then
  echo "✗ tutorial.pdf 不見：$PDF"
  exit 3
fi

export LIMN_BIN HEADLESS=0

cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  MINAD 補全生態系 — 完整 showcase
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Binary：$BIN_NOTE

  會發生：
    1. SBCL 啟動、載入 limn、開 Qt 視窗 + tutorial.pdf
    2. 幕 1–3：真 session 自動播放（你看 Qt 視窗，每幕確認 PASS/FAIL）
    3. 幕 4：印出 Corfu/Cape 後端真實計算

  建議：terminal 跟 Qt 視窗並排。

EOF

echo -n "按 RET 開始 / q+RET 取消："
read -r ans
case "$ans" in q|Q) exit 0 ;; esac

cd "$WORKSPACE"
exec bash "$WORKSPACE/backend/run-repl.sh" \
  --eval "(o \"$PDF\")" \
  --load "$WORKSPACE/scratch/minad-showcase.lisp"
