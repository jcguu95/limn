# cache-bust marker (content change to invalidate docker COPY layer)
TEMPLATE = app
TARGET = limn
VERSION = 0.3.0

INCLUDEPATH += ./pdf_viewer \
               mupdf/include \
               zlib

QT += core opengl gui widgets network quickwidgets svg texttospeech

greaterThan(QT_MAJOR_VERSION, 5){
	QT += openglwidgets
	DEFINES += SIOYEK_QT6
}
else{
	QT += openglextensions
}

CONFIG += c++17
DEFINES += QT_3DINPUT_LIB QT_OPENGL_LIB QT_OPENGLEXTENSIONS_LIB QT_WIDGETS_LIB

# ─── v0.37 A1c: bake build provenance into the binary ──────────────────
# Every Limn binary must self-report its git hash, compile time, and
# build environment (see limn_build_info.h).
#
# Two paths for provenance values:
#   1. Env var LIMN_BUILD_GIT_HASH etc. — set by docker --build-arg
#      via Dockerfile ENV.  Preferred because docker has no usable
#      .git (worktrees' .git is a gitdir: pointer to a host path).
#   2. $$system(git rev-parse) at qmake time — used on the host where
#      .git is available.  No-op inside docker (no git → empty result).
# Anything still empty after both falls back to "unknown" so the build
# never fails on a missing-provenance reason.

LIMN_GIT_HASH = $$(LIMN_BUILD_GIT_HASH)
isEmpty(LIMN_GIT_HASH): LIMN_GIT_HASH = $$system(cd $$_PRO_FILE_PWD_/.. 2>/dev/null && git rev-parse --short=12 HEAD 2>/dev/null)
isEmpty(LIMN_GIT_HASH): LIMN_GIT_HASH = unknown

LIMN_GIT_DIRTY = $$(LIMN_BUILD_GIT_DIRTY)
isEmpty(LIMN_GIT_DIRTY): LIMN_GIT_DIRTY = $$system(cd $$_PRO_FILE_PWD_/.. 2>/dev/null && (git diff-index --quiet HEAD -- 2>/dev/null && echo clean || echo dirty) 2>/dev/null)
isEmpty(LIMN_GIT_DIRTY): LIMN_GIT_DIRTY = unknown

LIMN_BUILD_TIME = $$(LIMN_BUILD_TIME)
isEmpty(LIMN_BUILD_TIME): LIMN_BUILD_TIME = $$system(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
isEmpty(LIMN_BUILD_TIME): LIMN_BUILD_TIME = unknown

# `uname -srm` is space-separated; qmake variable assignment treats
# spaces as list separators which then break DEFINES expansion
# (each space becomes a new -D argument).  Pipe through sed (qmake
# collapses `' '` literals in $$system(), so `tr ' ' '_'` doesn't
# survive substitution — sed avoids the literal-space issue).
LIMN_BUILD_HOST = $$system(uname -srm 2>/dev/null | sed -e s/[[:space:]]/_/g)
isEmpty(LIMN_BUILD_HOST): LIMN_BUILD_HOST = unknown

# Triple-escape: value passes through qmake → makefile → shell → compiler.
DEFINES += LIMN_BUILD_GIT_HASH=\\\"$$LIMN_GIT_HASH\\\"
DEFINES += LIMN_BUILD_GIT_DIRTY=\\\"$$LIMN_GIT_DIRTY\\\"
DEFINES += LIMN_BUILD_TIME=\\\"$$LIMN_BUILD_TIME\\\"
DEFINES += LIMN_BUILD_HOST=\\\"$$LIMN_BUILD_HOST\\\"
DEFINES += LIMN_BUILD_QT=\\\"$$[QT_VERSION]\\\"

RESOURCES += resources.qrc

HEADERS += \
    pdf_viewer/book.h \
    pdf_viewer/database.h \
    pdf_viewer/document.h \
    pdf_viewer/document_view.h \
    pdf_viewer/fts_fuzzy_match.h \
    pdf_viewer/rapidfuzz_amalgamated.hpp \
    pdf_viewer/main_widget.h \
    pdf_viewer/pdf_renderer.h \
    pdf_viewer/pdf_view_opengl_widget.h \
    pdf_viewer/checksum.h \
    pdf_viewer/coordinates.h \
    pdf_viewer/sqlite3.h \
    pdf_viewer/sqlite3ext.h \
    pdf_viewer/path.h \
    pdf_viewer/utf8.h \
    pdf_viewer/utils.h \
    pdf_viewer/utf8/checked.h \
    pdf_viewer/utf8/core.h \
    pdf_viewer/utf8/unchecked.h \
    pdf_viewer/limn_build_info.h \
    pdf_viewer/limn_options.h \
    pdf_viewer/limn_buffer_registry.h \
    pdf_viewer/limn_bridge.h \
    pdf_viewer/gap_buffer.h \
    pdf_viewer/limn_command.h \
    pdf_viewer/limn_engine_mupdf.h \
    pdf_viewer/limn_input.h \
    pdf_viewer/limn_window_registry.h \
    pdf_viewer/limn_chrome_bar.h \
    fzf/fzf.h

SOURCES += \
    pdf_viewer/config.cpp \
    pdf_viewer/book.cpp \
    pdf_viewer/database.cpp \
    pdf_viewer/document.cpp \
    pdf_viewer/document_view.cpp \
    pdf_viewer/main.cpp \
    pdf_viewer/main_widget.cpp \
    pdf_viewer/pdf_renderer.cpp \
    pdf_viewer/pdf_view_opengl_widget.cpp \
    pdf_viewer/checksum.cpp \
    pdf_viewer/coordinates.cpp \
    pdf_viewer/sqlite3.c \
    pdf_viewer/path.cpp \
    pdf_viewer/utils.cpp \
    pdf_viewer/limn_options.cpp \
    pdf_viewer/limn_buffer_registry.cpp \
    pdf_viewer/limn_bridge.cpp \
    pdf_viewer/gap_buffer.cpp \
    pdf_viewer/limn_command.cpp \
    pdf_viewer/limn_engine_mupdf.cpp \
    pdf_viewer/limn_input.cpp \
    pdf_viewer/limn_window_registry.cpp \
    pdf_viewer/limn_chrome_bar.cpp \
    fzf/fzf.c

# v0.37 A1d: macOS uses the same nix-built mupdf as Linux/docker so
# host ≡ container library versions.  Pre-v0.37 the mac block linked
# the vendored sioyek/mupdf/build/release which (a) requires
# initializing the mupdf submodule (~10 min cold build) and (b) lets
# host and container drift.  nix gives both sides the same 1.27+
# binary out-of-the-box.
mac {
    QMAKE_CXXFLAGS += -std=c++17
    # nix-built mupdf: single libmupdf + system third-party deps.
    LIBS += -lmupdf
    LIBS += -lz -lm -ldl
    LIBS += -lharfbuzz -lfreetype -ljpeg -lopenjp2 -ljbig2dec -lgumbo
    CONFIG+=sdk_no_version_check
    QMAKE_MACOSX_DEPLOYMENT_TARGET = 15
    ICON = pdf_viewer/icon2.ico
    QMAKE_INFO_PLIST = resources/Info.plist
    LIBS += -framework AppKit
    OBJECTIVE_SOURCES += pdf_viewer/macos_specific.mm
}

# Linux build path — used by the e2e container (Dockerfile, nix-based).
# nix shell sets NIX_CFLAGS_COMPILE / NIX_LDFLAGS so we don't need
# hardcoded INCLUDEPATH or library search paths — just declare what to
# link.  Same library set as mac { } above (single source of truth).
unix:!mac:!android {
    QMAKE_CXXFLAGS += -std=c++17
    LIBS += -lmupdf
    LIBS += -lz -lm -ldl
    LIBS += -lharfbuzz -lfreetype -ljpeg -lopenjp2 -ljbig2dec -lgumbo
}
