#!/usr/bin/env bash
# build-docker.sh — canonical way to build the Limn e2e docker image.
#
# Wraps `docker build` with --build-arg flags that bake host-side git
# provenance into the binary (git hash, dirty flag, build time).
#
# Why not `docker build .` directly?  The worktree's `.git` is a
# `gitdir:` pointer to a host abs path that doesn't exist inside the
# container, so we can't COPY it.  Build-arg sidesteps that.
#
# Usage:  bash scripts/build-docker.sh [extra docker build args...]
#         (default tag: limn-e2e:latest)
#
# Examples:
#   bash scripts/build-docker.sh
#   bash scripts/build-docker.sh -t limn-e2e:dev
#   bash scripts/build-docker.sh --no-cache

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

GIT_HASH="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY="$(git diff-index --quiet HEAD -- 2>/dev/null && echo clean || echo dirty)"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "── building docker image ───────────────────────────────────"
echo "  git hash   : $GIT_HASH"
echo "  git dirty  : $GIT_DIRTY"
echo "  build time : $BUILD_TIME"
echo "  extra args : $*"
echo "────────────────────────────────────────────────────────────"

# Default tag is limn-e2e:latest; user can override with -t.
HAS_TAG=0
for arg in "$@"; do
  case "$arg" in
    -t|--tag) HAS_TAG=1; break ;;
  esac
done
TAG_ARGS=()
[ "$HAS_TAG" -eq 0 ] && TAG_ARGS=(-t limn-e2e:latest)

DOCKER_BUILDKIT=1 exec docker build \
  --build-arg "LIMN_BUILD_GIT_HASH=$GIT_HASH" \
  --build-arg "LIMN_BUILD_GIT_DIRTY=$GIT_DIRTY" \
  --build-arg "LIMN_BUILD_TIME=$BUILD_TIME" \
  "${TAG_ARGS[@]}" \
  "$@" \
  "$REPO_ROOT"
