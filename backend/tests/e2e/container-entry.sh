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
Xvfb "${DISPLAY}" -screen 0 1280x1024x24 -ac +extension RANDR \
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

# Start openbox — minimal WM. Without one, Qt's xcb backend doesn't get
# proper focus events and mouse delivery to child widgets gets weird
# (we hit this with batch-os-click: mouse-click event never fired even
# though Qt window was visible at right coords).
openbox --sm-disable > /tmp/openbox.log 2>&1 &
OPENBOX_PID=$!
sleep 0.3

# v0.14: rebuild fontconfig cache so freshly-installed fonts (DejaVu Sans
# etc) are findable by Qt's font matching at runtime. Without this, Qt
# silently falls back and any test requesting a specific font sees
# glyphs-substituted > 0 even though the font is on disk.
fc-cache -f > /tmp/fc-cache.log 2>&1 || true

# v0.14: force software OpenGL. Xvfb has no GPU, libglvnd alone can't
# render anything; we need mesa's swrast / llvmpipe driver. Without
# this, QOpenGLWidget::grabFramebuffer() returns a null/zero image
# and overlay paint tests can't sample any pixels.
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe

# Optional x11vnc for live debug (map -p 5900:5900 on host).
if [ "${X11VNC:-0}" = "1" ]; then
  x11vnc -display "${DISPLAY}" -nopw -forever -shared \
         -rfbport 5900 -bg -o /tmp/x11vnc.log
  echo "→ x11vnc on :5900 (host: vnc://localhost:5900)"
fi

cleanup() {
  for pid in ${OPENBOX_PID:-} ${XVFB_PID:-}; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

# Now exec whatever was asked for.
exec "$@"
