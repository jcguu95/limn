#!/usr/bin/env bash
# build-runtime.sh —— build limn 的 OpenHands 自訂 runtime image。
#
# 為什麼要 wrapper：runtime 的 Dockerfile 住在 meta/openhands/，但要 COPY repo 根
# 的 flake.nix / flake.lock，所以 build context 必須是 repo 根（不是 meta/openhands/）。
#
# 用法：
#   bash meta/openhands/build-runtime.sh             # 預設 tag limn-openhands-runtime:0.57.2
#   bash meta/openhands/build-runtime.sh --no-cache  # 強制重 build
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OH_VERSION="${OH_VERSION:-0.57.2}"
TAG="${TAG:-limn-openhands-runtime:${OH_VERSION}}"

# 鐵律 provenance：把 build 當下的 flake.lock sha + nixpkgs rev 烤成 image label，
# 方便 `docker inspect` 一眼看出這 image 鎖的是哪個 lock（真相仍是 image 內
# /limn/flake.lock，check-lock-sync.sh 讀的是那個檔，label 只是給人看的快照）。
if command -v shasum >/dev/null 2>&1; then
  LOCK_SHA=$(shasum -a 256 "$REPO_ROOT/flake.lock" | awk '{print $1}')
else
  LOCK_SHA=$(sha256sum "$REPO_ROOT/flake.lock" | awk '{print $1}')
fi
NIXPKGS_REV=$(grep -A6 '"nixpkgs"' "$REPO_ROOT/flake.lock" | grep '"rev"' | head -1 | grep -oE '[0-9a-f]{40}')

echo ">>> build context : $REPO_ROOT"
echo ">>> dockerfile    : meta/openhands/Dockerfile.runtime"
echo ">>> tag           : $TAG"
echo ">>> base          : ghcr.io/all-hands-ai/runtime:${OH_VERSION}-nikolaik"
echo ">>> flake.lock    : $LOCK_SHA"
echo ">>> nixpkgs rev   : $NIXPKGS_REV"
echo ">>> ⚠ 首次 build 重：23.5GB nikolaik base + nix closure 下載，需數分鐘"

cd "$REPO_ROOT"
DOCKER_BUILDKIT=1 exec docker build \
  -f meta/openhands/Dockerfile.runtime \
  --build-arg "OH_VERSION=${OH_VERSION}" \
  --label "limn.flake_lock_sha256=${LOCK_SHA}" \
  --label "limn.nixpkgs_rev=${NIXPKGS_REV}" \
  -t "$TAG" \
  "$@" \
  "$REPO_ROOT"
