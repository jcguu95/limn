#!/usr/bin/env bash
# verify-limn-client.sh —— limn-client（emacsclient 風格 eval）互動驗證 walkthrough。
#
# 在「本機 macOS」跑。這個 script 會：
#   1. 在背景起一個 limn backend + eval-server（純後端，不需要 build C++ frontend）
#   2. 用 scripts/limn-client 從「外部」連進去 eval 幾個 Lisp form
#   3. 每步印「預期看到什麼」，你比對實際輸出後回答 y/n/c/a
#      （y=一致 n=不一致 c=不一致並留言 a=中止）
#
# 怎麼跑（絕對路徑，複製貼上即可）：
#   bash /Users/jin/data/local/projects/limn-deepseek/scratch/verify-limn-client.sh
#
# 注意：首次會 nix develop 編譯 backend（約 30–60 秒），請耐心等 server 起來。
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOCK="/tmp/limn-eval-walkthrough.sock"
CLIENT="$REPO/scripts/limn-client"
SERVER_LISP="/tmp/limn-eval-walkthrough-server.lisp"
SERVER_LOG="/tmp/limn-eval-walkthrough-server.log"
SERVER_PID=""

cleanup() {
  echo ""
  echo ">>> 關閉 eval-server、清理 socket..."
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -f "$SOCK"
}
trap cleanup EXIT

echo "═══════════════════════════════════════════════"
echo "  limn-client 互動驗證（emacsclient 風格 eval）"
echo "═══════════════════════════════════════════════"
echo "repo   : $REPO"
echo "socket : $SOCK"
echo "client : $CLIENT"
echo ""
echo "這會背景起一個 limn backend + eval-server，再從外部 eval form。"
read -r -p "按 Enter 開始..." _

# ── 背景起 eval-server（純 backend SBCL，逐 form load 避開 read-time 問題）──
cat > "$SERVER_LISP" <<LISP
(require :asdf)
(require :sb-posix)
(require :sb-bsd-sockets)
(push #p"$REPO/backend/" asdf:*central-registry*)
(asdf:initialize-source-registry)
(handler-bind ((warning #'muffle-warning))
  (asdf:load-system :limn))
(limn/eval-server:start-server :path "$SOCK" :force t)
(format t "~&READY socket=~a~%" limn/eval-server:*socket-path*)
(force-output)
(loop (sleep 1))
LISP

echo ""
echo ">>> 啟動 eval-server（首次 load 約 30–60 秒編譯）..."
( cd "$REPO" && nix develop --command sbcl --non-interactive --load "$SERVER_LISP" ) \
  > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 120); do [ -S "$SOCK" ] && break; sleep 1; done
if [ ! -S "$SOCK" ]; then
  echo "✗ server 沒起來。看 log：$SERVER_LOG"
  tail -20 "$SERVER_LOG"
  exit 1
fi
echo ">>> eval-server 起好了 ✓（socket 已就緒）"

PASS=0; FAIL=0
step() {
  local desc="$1" form="$2" expect="$3"
  echo ""
  echo "──────────────────────────────────────────────"
  echo "步驟：$desc"
  echo "  指令：limn-client --eval '$form'"
  echo "  預期看到：$expect"
  echo "  ── 實際輸出 ──"
  LIMN_EVAL_SOCK="$SOCK" "$CLIENT" --eval "$form" 2>&1 | sed 's/^/    /'
  echo "  ──────────────"
  read -r -p "  一致嗎？[y/n/c/a] " ans
  case "$ans" in
    y|Y) PASS=$((PASS+1));;
    a|A) echo "  中止。"; exit 0;;
    c|C) read -r -p "  留言：" cm; echo "  [備註] $cm"; FAIL=$((FAIL+1));;
    *)   FAIL=$((FAIL+1));;
  esac
}

step "基本 eval（從外部 socket 注入算式）" \
     "(+ 1 2)" "最後一行是 3"
step "stdout 捕捉 + 回傳結果" \
     '(progn (princ "hello from limn") 42)' "先看到 hello from limn，下一行 42"
step "查 limn 真實狀態（證明連到的是 limn 大腦，不是隨便一個 sbcl）" \
     "(limn/buffer:count-buffers)" "0（backend-only 沒開 buffer）"
step "one-shot 多次連線（每次新連線都 work）" \
     "(* 6 7)" "42"
step "錯誤被好好回傳（server 不會崩）" \
     "(/ 1 0)" "以 ERROR: 開頭的錯誤訊息（例如 division by zero）"
step "上個 error 後 server 仍活著" \
     "(list 1 2 3)" "(1 2 3)"

echo ""
echo "═══════════════════════════════════════════════"
echo "  結果：$PASS 通過 / $FAIL 不一致"
echo "═══════════════════════════════════════════════"
echo "全部通過代表：外部能連到 running limn、注入 form、拿回正確結果 +"
echo "stdout + 錯誤處理，且在本機 macOS 成功 → limn-client 可以 merge。"
