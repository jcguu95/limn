TEMPLATE = app
TARGET = sioyek
VERSION = 2.0.0

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
