#!/usr/bin/env bash
#
# 一鍵跑 Ibuffer mode 的 GUI walkthrough。
#
# 1. 用 main repo 的 sioyek binary（worktree 沒有 binary，只有 source）
# 2. HEADLESS=0 → 跳真 Qt 窗
# 3. 自動開 tutorial.pdf
# 4. 載入 scratch/ibuffer-walkthrough.lisp，逐步走 15 個 GUI step
# 5. 走完 drop 到 SBCL REPL 給你繼續玩
#
# 用法：
#   bash /Users/jin/data/local/projects/sioyek-core/scratch/run-ibuffer-walkthrough.sh

set -u

REPO=/Users/jin/data/local/projects/sioyek-core
PDF="$REPO/sioyek/tutorial.pdf"

export LIMN_BIN="$REPO/sioyek/limn.app/Contents/MacOS/limn"
if [ ! -x "$LIMN_BIN" ]; then
  echo "✗ 還沒 build sioyek binary：$LIMN_BIN（先跑 scripts/build-macos.sh）"
fi

if [ ! -x "$LIMN_BIN" ]; then
  echo "✗ 找不到 sioyek binary：$LIMN_BIN"
  exit 2
fi

if [ ! -f "$PDF" ]; then
  echo "✗ tutorial.pdf 不見：$PDF"
  exit 3
fi

# Driver 會幫你開 /tmp/foo.txt 當第二個 buffer。
if [ ! -f /tmp/foo.txt ]; then
  printf 'ibuffer GUI test placeholder\n第二個 buffer 用的假檔。\n' >/tmp/foo.txt
fi

export HEADLESS=0
export LIMN_BIN

cat <<'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Ibuffer GUI Walkthrough
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

接下來會發生這些事：
  1. SBCL 啟動、編 / 載入 worktree 的 limn 系統
  2. spawn sioyek binary（HEADLESS=0 → 跳真窗）
  3. 自動開 tutorial.pdf 進 w1
  4. 進入 walkthrough：driver 印 step 提示，你在 Qt 窗操作，
     回 terminal 按 RET 確認
  5. 走完 drop 到 SBCL prompt，你可以繼續玩

建議：terminal 跟 Qt 窗並排，你會一直在兩邊切。

EOF

echo -n "按 RET 開始 / q+RET 取消："
read -r START
case "$START" in
  q|Q) exit 0 ;;
esac

cd "$REPO"

# Forward to run-repl.sh:
#   --eval '(o ...)'        opens tutorial.pdf via the bridge
#   --load tmp/...driver    walks user through 15 steps then returns
#                           to REPL (SBCL prompt — (q) to quit)
exec bash "$REPO/backend/run-repl.sh" \
  --eval "(o \"$PDF\")" \
  --load "$REPO/scratch/ibuffer-walkthrough.lisp"
