#!/usr/bin/env bash
# dogfood-split.sh — 一鍵啟動可見 Qt、開檔、左右切成兩個獨立 pane，
# 然後落到 SBCL 互動提示字元，讓你親手驗證 Phase 3b 的視窗分割。
#
# 用法：
#   ./backend/dogfood-split.sh                       # 開 sioyek/tutorial.pdf，水平分割
#   ./backend/dogfood-split.sh /path/to.pdf          # 指定 PDF
#   ./backend/dogfood-split.sh /path/to.pdf v        # 垂直分割（上/下）
#
# 落到提示字元後可手動操作（見 backend/SPLIT-DOGFOOD-CHECKLIST.md）：
#   (sp "h")    再水平分割 focused pane
#   (sp "v")    垂直分割
#   (wf "w2")   把焦點（邊框＋鍵盤）移到 w2
#   (wc "w2")   關掉 w2 這個 pane
#   (wins)      列出所有 window
#   (tree)      印出 Qt widget 樹（含 *FOCUS* 標記）
#   (q)         離開（會殺掉 limn 子行程）
#
# 注意：focused pane 才會被鍵盤導航（j/k 等）驅動；key 事件不帶 win-id，
# 由 backend 自己的 focused window 派發，set_focused_win 重指 document_view_。

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

echo "→ 開檔：$PDF"
echo "→ 分割方向：$DIR（h=左右、v=上下）"
echo "→ 啟動可見 Qt，開檔後自動分割成兩個獨立 pane，再落到 SBCL 提示字元。"
echo

# HEADLESS=0 → 可見 Qt 視窗。把開檔、pump、分割串成依序的 --eval；
# 開檔是非同步安裝 pdf-mode 的，所以中間夾一個 sleep + pump 讓 buffer-opened
# 事件先落地，再讀 registry 做分割。run-repl.sh 會把這些 --eval 轉發給 sbcl。
exec env HEADLESS=0 "$PROJECT_ROOT/backend/run-repl.sh" \
  --eval "(o \"$PDF\")" \
  --eval '(sleep 0.4)' \
  --eval '(p)' \
  --eval "(sp \"$DIR\")" \
  --eval '(format t "~%━━ 兩個 pane 已就緒。試試 (wf \"w2\") 移動焦點、(wc \"w2\") 關閉，(q) 離開 ━━~%~%")'
