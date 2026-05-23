#!/usr/bin/env bash
# Container entrypoint — start Xvfb (and optionally x11vnc), then exec
# whatever command was passed as CMD.
#
# DISPLAY is preset by the Dockerfile to :99.
#
# Env switches:
#   X11VNC=1   also start x11vnc on :5900 so host can VNC in for live
#              visual debugging (export -p 5900:5900 when docker run)

set -u

# Start Xvfb in the background.
Xvfb "${DISPLAY}" -screen 0 1280x800x24 -ac +extension RANDR \
     > /tmp/xvfb.log 2>&1 &
XVFB_PID=$!

# Wait until the X server is actually responding.
for i in $(seq 1 50); do
  if xdpyinfo > /dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if ! xdpyinfo > /dev/null 2>&1; then
  echo "✗ Xvfb didn't come up. /tmp/xvfb.log:"
  cat /tmp/xvfb.log
  exit 3
fi

# Optional x11vnc for live debug (map -p 5900:5900 on host).
if [ "${X11VNC:-0}" = "1" ]; then
  x11vnc -display "${DISPLAY}" -nopw -forever -shared \
         -rfbport 5900 -bg -o /tmp/x11vnc.log
  echo "→ x11vnc on :5900 (host: vnc://localhost:5900)"
fi

cleanup() {
  if [ -n "${XVFB_PID:-}" ] && kill -0 "$XVFB_PID" 2>/dev/null; then
    kill "$XVFB_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Now exec whatever was asked for.
exec "$@"
