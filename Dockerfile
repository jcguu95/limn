# Limn e2e container — Debian slim base, Qt6 + sbcl + mupdf + xdotool + Xvfb.
#
# Two-stage:
#   builder  compiles Limn for Linux (qmake6 + make)
#   runtime  copies the binary in, plus Xvfb + xdotool + sbcl for tests
#
# Build (from repo root):
#   docker build -t limn-e2e .
#
# Run interactive:
#   docker run --rm -it -p 5900:5900 limn-e2e bash
#
# Run e2e tests:
#   docker run --rm limn-e2e backend/tests/e2e/run-os-e2e.sh

# ── builder stage ─────────────────────────────────────────────────────
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    qt6-base-dev qt6-base-private-dev \
    libmupdf-dev mupdf-tools \
    libfreetype-dev libharfbuzz-dev libjpeg-dev \
    build-essential pkg-config \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY sioyek/ ./sioyek/

# Limn's qmake project file is sioyek/pdf_viewer/pdf_viewer_build_config.pri
# referenced by sioyek/sioyek.pro. Linux build uses qmake6 → Makefile → make.
WORKDIR /build/sioyek
RUN qmake6 sioyek.pro \
 && make -j"$(nproc)"

# ── runtime stage ─────────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    qt6-base \
    libmupdf24 \
    libfreetype6 libharfbuzz0b libjpeg62-turbo \
    sbcl \
    xvfb xdotool x11vnc xauth \
    fontconfig fonts-dejavu-core \
    bash coreutils procps \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /limn
COPY --from=builder /build/sioyek/sioyek /limn/sioyek/limn
COPY backend/ /limn/backend/

# Xvfb display number + size — match what tests expect (DISPLAY=:99).
ENV DISPLAY=:99
ENV LIMN_BIN=/limn/sioyek/limn
ENV LIMN_BACKEND_DIR=/limn/backend/

COPY backend/tests/e2e/container-entry.sh /usr/local/bin/container-entry.sh
RUN chmod +x /usr/local/bin/container-entry.sh

ENTRYPOINT ["/usr/local/bin/container-entry.sh"]
CMD ["backend/tests/e2e/run-os-e2e.sh"]
