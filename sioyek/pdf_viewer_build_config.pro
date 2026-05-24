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

mac {
    QMAKE_CXXFLAGS += -std=c++17
    LIBS += -ldl -L$$PWD/mupdf/build/release -lmupdf -lmupdf-third -lmupdf-threads -lz
    CONFIG+=sdk_no_version_check
    QMAKE_MACOSX_DEPLOYMENT_TARGET = 15
    ICON = pdf_viewer/icon2.ico
    QMAKE_INFO_PLIST = resources/Info.plist
    LIBS += -framework AppKit
    OBJECTIVE_SOURCES += pdf_viewer/macos_specific.mm
}

# Linux build path — used by the e2e container (Dockerfile, nix-based).
# Uses nixpkgs mupdf (1.27+, same version as macOS dev shell). nix
# shell sets NIX_CFLAGS_COMPILE / NIX_LDFLAGS so we don't need hardcoded
# INCLUDEPATH or library search paths — just declare what to link.
unix:!mac:!android {
    QMAKE_CXXFLAGS += -std=c++17
    # nix-built mupdf is a single libmupdf; third-party deps (harfbuzz /
    # freetype / jpeg / openjp2 / jbig2dec / gumbo) are linked separately
    # at the final binary, not bundled into libmupdf-third like sioyek's
    # vendored build does.
    LIBS += -lmupdf
    LIBS += -lz -lm -ldl
    LIBS += -lharfbuzz -lfreetype -ljpeg -lopenjp2 -ljbig2dec -lgumbo
}
