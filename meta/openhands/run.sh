#!/usr/bin/env bash
# run.sh —— 用 OpenHands + DeepSeek 開發 limn。
#
# 架構（對照 README）：
#   OpenHands app container（web UI @ :3000）負責編排；agent 實際在我們的
#   自訂 runtime image（limn-openhands-runtime，FROM nikolaik + nix + limn
#   flake#docker）裡執行指令 —— 所以 agent 能 `nix develop /limn#docker` build
#   limn、跑 headless e2e、VNC 看 GUI。
#
# 前置：
#   1. bash meta/openhands/build-runtime.sh          # 先 build runtime image（一次）
#   2. ~/.authinfo 有 `machine deepseek.api ... password <KEY>`
#
# 用法：
#   bash meta/openhands/run.sh                        # 預設掛 repo 根當 workspace
#   WORKSPACE=/path/to/worktree bash meta/openhands/run.sh   # 指定 worktree（建議！）
#
# ⚠ GIT 安全：agent 會在 workspace 裡就地改檔。**強烈建議** WORKSPACE 指向一個
#    專用 git worktree（而非 main 工作樹），這樣 agent 的改動天生落在自己的分支、
#    永遠不會直接動到 main。limn 的 CLAUDE.md 已有 git 安全規則（只在使用者明確
#    要求時才 commit/push、不 force-push…），但 DeepSeek 未必像 Claude 一樣嚴守，
#    所以用 worktree 做硬隔離。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OH_VERSION="${OH_VERSION:-0.57.2}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-limn-openhands-runtime:${OH_VERSION}}"
WORKSPACE="${WORKSPACE:-$REPO_ROOT}"

# 從 ~/.authinfo 讀 DeepSeek key（永遠不 bake 進 image / 環境檔）。
DEEPSEEK_API_KEY=$(grep -i "machine deepseek.api" ~/.authinfo \
  | awk '{for(i=1;i<=NF;i++) if($i=="password") print $(i+1)}')
if [[ -z "$DEEPSEEK_API_KEY" ]]; then
  echo "錯誤：~/.authinfo 找不到 deepseek.api 的 password 欄位" >&2
  exit 1
fi

# runtime image 在不在？不在就擋下來，提示先 build。
if ! docker image inspect "$RUNTIME_IMAGE" &>/dev/null; then
  echo "錯誤：找不到 runtime image '$RUNTIME_IMAGE'。" >&2
  echo "      先跑：bash meta/openhands/build-runtime.sh" >&2
  exit 1
fi

# ── 鐵律守門（CLAUDE.md §0）：image 的 flake.lock 必須 == repo 的 ──────────
# 不一致 = DeepSeek 與 host 跑在不同依賴版本上 → 硬擋，不啟動。
RUNTIME_IMAGE="$RUNTIME_IMAGE" bash "$SCRIPT_DIR/check-lock-sync.sh" || {
  echo "啟動中止：nix 依賴鎖不一致（見上方警報）。先 build-runtime.sh 再來。" >&2
  exit 1
}

echo ">>> Workspace : $WORKSPACE"
echo ">>> Runtime   : $RUNTIME_IMAGE"
echo ">>> 開啟後進  : http://localhost:3000"
if [[ "$WORKSPACE" == "$REPO_ROOT" ]]; then
  echo ">>> ⚠ 你掛的是 main 工作樹本身；agent 改動會就地發生。建議改用 worktree："
  echo ">>>   WORKSPACE=<worktree 路徑> bash meta/openhands/run.sh"
fi

docker run -it --rm \
  --platform linux/amd64 \
  -e SANDBOX_RUNTIME_CONTAINER_IMAGE="$RUNTIME_IMAGE" \
  -e WORKSPACE_MOUNT_PATH="$WORKSPACE" \
  -e LOG_ALL_EVENTS=true \
  -e LLM_MODEL="deepseek/deepseek-chat" \
  -e LLM_BASE_URL="https://api.deepseek.com/v1" \
  -e LLM_API_KEY="$DEEPSEEK_API_KEY" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.openhands:/.openhands \
  -v "$WORKSPACE":/opt/workspace_base \
  -p 3000:3000 \
  --add-host host.docker.internal:host-gateway \
  --name openhands-limn \
  "ghcr.io/all-hands-ai/openhands:${OH_VERSION}"
