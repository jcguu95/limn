#!/usr/bin/env bash
# Nuke the docker buildkit ccache mount used by the limn-e2e image.
#
# WHEN TO RUN THIS:
#   You're debugging a weird build / link / runtime symptom and you
#   want to *prove* it's not stale-cache corruption before sinking
#   more time. Run this, then `docker build --no-cache -t limn-e2e .`
#   to do a clean-room build.
#
# WHAT IT DOES:
#   Removes the buildkit cache mount layer that backs ccache's
#   /root/.ccache directory inside the build. ccache will start
#   empty on the next build and full-recompile everything (~3-5 min).
#
# WHAT IT DOES NOT DO:
#   Touch the nix-store layer cache, your local docker images, or
#   the host `sioyek/` build artifacts. Pure ccache flush.
#
# See Dockerfile and CONTRIBUTING.org §Build Cache for context.

set -eu

echo "→ pruning buildkit exec-cache mounts (ccache lives here)..."
docker builder prune --filter type=exec.cachemount --force

echo
echo "✓ ccache mount gone. Next 'docker build' will be a full rebuild"
echo "  (~3-5 min). After it succeeds, subsequent builds get ccache hits"
echo "  back and return to fast incremental times."
