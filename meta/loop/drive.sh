#!/usr/bin/env bash
# drive.sh —— thin loop 的入口（Claude 從這裡驅動 DeepSeek）。
#
# 做三件事：(1) 確保沙箱起著、(2) 開一個 run 目錄、(3) 跑 loop.py。
# 結束後 status.json 的路徑會印出來 —— Claude 只讀那個檔，不讀 transcript。
#
# 用法：
#   bash meta/loop/drive.sh <brief.md> <workspace 絕對路徑> [--continue]
#
# 範例：
#   bash meta/loop/drive.sh /tmp/brief-search.md /Users/jin/data/local/projects/limn-deepseek
#
# 前置：
#   - runtime image 已 build（bash meta/openhands/build-runtime.sh）
#   - workspace 是 limn 的 git clone、已 checkout 一個自己的分支（git 隔離）
#   - ~/.authinfo 有 deepseek.api 的 password
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BRIEF="${1:-}"; WORKSPACE="${2:-}"; shift 2 2>/dev/null || true
EXTRA=("$@")   # 例如 --continue

[[ -z "$BRIEF" || -z "$WORKSPACE" ]] && {
  echo "用法：bash meta/loop/drive.sh <brief.md> <workspace 絕對路徑> [--continue]" >&2; exit 1; }
[[ -f "$BRIEF" ]] || { echo "錯誤：brief 不存在：$BRIEF" >&2; exit 1; }
[[ -d "$WORKSPACE" ]] || { echo "錯誤：workspace 不存在：$WORKSPACE" >&2; exit 1; }
command -v python3 >/dev/null || { echo "錯誤：host 上沒有 python3" >&2; exit 1; }

# 沙箱起了沒？沒有就起（sandbox.sh 內含鐵律守門）。
if ! bash "$SCRIPT_DIR/sandbox.sh" status | grep -q Up; then
  echo ">>> 沙箱沒在跑，啟動中…"
  bash "$SCRIPT_DIR/sandbox.sh" up "$WORKSPACE"
fi

RUN_DIR="$SCRIPT_DIR/.runs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
echo ">>> brief    : $BRIEF"
echo ">>> workspace: $WORKSPACE"
echo ">>> run dir  : $RUN_DIR"
echo ""

python3 "$SCRIPT_DIR/loop.py" \
  --brief "$BRIEF" \
  --workspace "$WORKSPACE" \
  --run-dir "$RUN_DIR" \
  "${EXTRA[@]}"
