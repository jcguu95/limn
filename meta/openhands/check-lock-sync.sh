#!/usr/bin/env bash
# check-lock-sync.sh —— nix 依賴單一版本鐵律的守門員。
#
# 鐵律（CLAUDE.md §0）：host（macOS 上的人 / Claude）與容器（DeepSeek）測試與
# 跑動所用的**所有依賴**，一律經 `nix develop` 鎖在**同一個 `flake.lock`**。
#
# host 每次 `nix develop` 都讀「現場」的 flake.lock，永遠不會過期。唯一會 drift
# 的是 OpenHands runtime image **烤進去**的那份 lock（build 當下的快照）。所以
# 守門點只有一個：image 內 /limn/flake.lock 的 sha256 必須 == repo flake.lock。
#
# 不一致 = 鐵律被打破 → 印巨大警報、exit 1。run.sh 會在啟動前呼叫本檔，不通就
# 拒絕啟動 DeepSeek。
#
# 用法：bash meta/openhands/check-lock-sync.sh
#   exit 0 = 一致；1 = 不一致（報警）；2 = image 不存在。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OH_VERSION="${OH_VERSION:-0.57.2}"
IMAGE="${RUNTIME_IMAGE:-limn-openhands-runtime:${OH_VERSION}}"

# repo 端：用 shasum（macOS）或 sha256sum（Linux），擇一存在者。
if command -v shasum >/dev/null 2>&1; then
  repo_sha=$(shasum -a 256 "$REPO_ROOT/flake.lock" | awk '{print $1}')
else
  repo_sha=$(sha256sum "$REPO_ROOT/flake.lock" | awk '{print $1}')
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "⚠ runtime image '$IMAGE' 不存在 —— 先跑：bash meta/openhands/build-runtime.sh" >&2
  exit 2
fi

# image 端：直接讀烤進去的真檔（override entrypoint，快、且是真相，不靠 label）。
img_sha=$(docker run --rm --entrypoint sha256sum "$IMAGE" /limn/flake.lock | awk '{print $1}')

if [[ "$repo_sha" == "$img_sha" ]]; then
  echo "✅ nix 依賴鎖一致：repo == image（DeepSeek 與 host 同版本）"
  echo "   flake.lock sha256 = $repo_sha"
  exit 0
fi

# ── 巨大警報 ──────────────────────────────────────────────────────────────
{
  echo ""
  echo "████████████████████████████████████████████████████████████████████"
  echo "█                                                                  █"
  echo "█   🚨🚨🚨   NIX 依賴版本不一致 —— 鐵律被打破   🚨🚨🚨            █"
  echo "█                                                                  █"
  echo "████████████████████████████████████████████████████████████████████"
  echo ""
  echo "  repo  flake.lock sha256 : $repo_sha"
  echo "  image flake.lock sha256 : $img_sha"
  echo ""
  echo "  → DeepSeek（容器）與 host（你 / Claude）此刻跑在**不同**的依賴版本上。"
  echo "    這違反 CLAUDE.md §0『三方鎖同一個 flake.lock』鐵律。"
  echo "    在不同版本上做的測試與驗證，結論不可信。"
  echo ""
  echo "  修法：重 build runtime image，讓它吃到最新的 flake.lock —"
  echo "    bash meta/openhands/build-runtime.sh"
  echo ""
  echo "████████████████████████████████████████████████████████████████████"
  echo ""
} >&2
exit 1
