#!/usr/bin/env bash
# sandbox.sh —— 管理 thin loop 用的「持久沙箱容器」。
#
# loop.py 把**檔案操作**直接在 host 上做（workspace 是 host bind-mount，改 host
# 等於改容器內 /workspace）；只有 **run_command + 驗證** 需要 Linux/nix 工具鏈，
# 走 `docker exec` 進這個沙箱。所以沙箱要一直活著、掛好 workspace。
#
# 用法：
#   bash meta/loop/sandbox.sh up <workspace 絕對路徑>   # 起一個持久沙箱
#   bash meta/loop/sandbox.sh down                       # 停掉並移除
#   bash meta/loop/sandbox.sh exec -- <cmd...>           # 在沙箱 /workspace 內跑
#   bash meta/loop/sandbox.sh status                     # 看狀態
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OH_VERSION="${OH_VERSION:-0.57.2}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-limn-openhands-runtime:${OH_VERSION}}"
NAME="${SANDBOX_NAME:-limn-loop-sandbox}"

cmd="${1:-}"; shift || true

case "$cmd" in
  up)
    WORKSPACE="${1:-}"
    [[ -z "$WORKSPACE" ]] && { echo "用法：sandbox.sh up <workspace 絕對路徑>" >&2; exit 1; }
    [[ -d "$WORKSPACE" ]] || { echo "錯誤：workspace 不存在：$WORKSPACE" >&2; exit 1; }

    # 鐵律守門（CLAUDE.md §0）：沙箱 image 的 flake.lock 必須 == repo 的。
    RUNTIME_IMAGE="$RUNTIME_IMAGE" bash "$REPO_ROOT/meta/openhands/check-lock-sync.sh" || {
      echo "沙箱啟動中止：nix 依賴鎖不一致。先 bash meta/openhands/build-runtime.sh" >&2
      exit 1
    }

    if docker inspect "$NAME" &>/dev/null; then
      echo "沙箱 '$NAME' 已存在（先 down 再 up 可換 workspace）。"
      exit 0
    fi
    # override entrypoint（不要 OpenHands 的 action server），純睡著等 docker exec。
    docker run -d --name "$NAME" \
      -e LANG=C.UTF-8 -e LC_ALL=C.UTF-8 \
      -v "$WORKSPACE:/workspace" \
      --entrypoint bash \
      "$RUNTIME_IMAGE" \
      -lc 'sleep infinity'
    echo "✅ 沙箱 '$NAME' 起好了，workspace=$WORKSPACE → /workspace"
    ;;

  down)
    docker rm -f "$NAME" &>/dev/null && echo "✅ 沙箱 '$NAME' 已移除" || echo "（沒有 '$NAME' 在跑）"
    ;;

  exec)
    [[ "${1:-}" == "--" ]] && shift
    docker exec -w /workspace "$NAME" bash -lc "$*"
    ;;

  status)
    if docker inspect "$NAME" &>/dev/null; then
      docker ps --filter "name=$NAME" --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
    else
      echo "（沒有 '$NAME'）"
    fi
    ;;

  *)
    echo "用法：sandbox.sh {up <workspace>|down|exec -- <cmd>|status}" >&2
    exit 1
    ;;
esac
