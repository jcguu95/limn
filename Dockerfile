# Limn e2e container — nix-based.
#
# We tried apt-managed Debian first (e518f02). Hit two walls:
#   - Qt 6.4.2 on Debian bookworm is older than what sioyek expects
#     (QTextToSpeech::sayingWord / engineCapabilities are 6.5+)
#   - libmupdf 1.20.3 on Debian doesn't have fz_page_label etc.
#
# nix gives us the same versions as the macOS dev shell (Qt 6.11,
# mupdf 1.27+) — same flake on either platform. So the container is
# nix-based.
#
# Build:    docker build -t limn-e2e .
# Run e2e:  docker run --rm limn-e2e
# Debug:    docker run --rm -it -p 5900:5900 -e X11VNC=1 limn-e2e bash

# ── nix base ────────────────────────────────────────────────────────────
FROM nixos/nix:latest

# Enable flakes (needed for our flake.nix).
RUN mkdir -p /etc/nix && \
    echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

WORKDIR /limn

# Copy just the flake first so the dep closure gets cached in its own
# layer — code changes won't bust the nix-store closure.
COPY flake.nix flake.lock /limn/

# Materialise the dev shell so the closure is fetched once at build time.
RUN nix develop --command true

# Add the OS-level tools the e2e flow needs but the dev shell doesn't
# (Xvfb / xdotool / x11vnc / sbcl / fonts + a minimal window manager so
# Qt's xcb backend gets ICCCM-conformant focus/mouse delivery). Done as
# a fresh nix-env install rather than amending flake.nix because they
# aren't macOS dev needs.
#
# NB: this layer MUST sit *above* the source COPYs — otherwise every
# tiny .cpp / .lisp change re-invalidates the ~700MB nixpkgs reinstall
# and adds ~30s of pointless rework per incremental build.
RUN nix-env -iA \
      nixpkgs.xorg.xvfb \
      nixpkgs.xdotool \
      nixpkgs.x11vnc \
      nixpkgs.xorg.xdpyinfo \
      nixpkgs.openbox \
      nixpkgs.sbcl \
      nixpkgs.dejavu_fonts \
      nixpkgs.noto-fonts \
      nixpkgs.noto-fonts-cjk-sans \
      nixpkgs.bash \
      nixpkgs.coreutils \
      nixpkgs.fontconfig \
      nixpkgs.mesa \
      nixpkgs.mesa-demos \
      nixpkgs.ccache \
      nixpkgs.fcitx5 \
      nixpkgs.kdePackages.fcitx5-chinese-addons \
      nixpkgs.wmctrl \
      nixpkgs.xorg.xprop \
      nixpkgs.inotify-tools

# Now copy the actual source. Only this and the build step below get
# re-run on incremental changes.
COPY sioyek/  /limn/sioyek/
COPY backend/ /limn/backend/

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Build Limn — with ccache via buildkit cache mount.
#
# ⚠  DEBUGGING A WEIRD BUILD / LINK / RUNTIME ERROR? READ THIS FIRST.
#
# This step compiles ~80 C++ files; without ccache, every incremental
# `docker build` recompiles all of them from scratch (~3-5 min on
# Apple Silicon → linux/amd64 Rosetta translation). ccache is content-
# hashed (compiler args + preprocessed source), NOT mtime-based, so
# it is *almost-always safe* — branch switches, file moves, COPY
# mtime-loss, none of those fool it.
#
# But "almost-always" is not "always". If you are seeing ANY of:
#   • undefined symbol at link time on code you can `grep` and see
#   • segfault inside Qt before main() returns
#   • a test that passes on host but fails in container (or vice versa)
#   • "I rebuilt and the change didn't take effect" loop
#   • clang ICE / "compiler crashed" with a stack trace inside ccache
# the cache may be corrupted or holding stale objects from a toolchain
# bump. NUKE it before going any further:
#
#   bash scripts/nuke-build-cache.sh
#
# (which runs `docker builder prune --filter type=exec.cachemount -f`)
# Then `docker build --no-cache -t limn-e2e .` to confirm.
#
# See CONTRIBUTING.org §Build Cache for the full rationale and history.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RUN --mount=type=cache,id=limn-ccache,target=/root/.ccache,sharing=locked \
    cd sioyek && \
    nix develop /limn --command bash -c '\
      export CCACHE_DIR=/root/.ccache && \
      export CCACHE_MAXSIZE=5G && \
      ccache --zero-stats > /dev/null && \
      qmake QMAKE_CXX="ccache $CXX" QMAKE_CC="ccache $CC" \
            pdf_viewer_build_config.pro && \
      make -j$(nproc) && \
      echo "── ccache stats after build ──" && \
      ccache --show-stats'

# Runtime config — match what backend/tests/e2e/run-os-e2e.sh expects.
ENV DISPLAY=:99
ENV LIMN_BIN=/limn/sioyek/limn
ENV LIMN_BACKEND_DIR=/limn/backend/

COPY backend/tests/e2e/container-entry.sh /usr/local/bin/container-entry.sh
RUN chmod +x /usr/local/bin/container-entry.sh

ENTRYPOINT ["/usr/local/bin/container-entry.sh"]
CMD ["backend/tests/e2e/run-os-e2e.sh"]
