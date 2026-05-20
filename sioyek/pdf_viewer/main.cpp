#include <mutex>
#include <qapplication.h>
#include <qsurfaceformat.h>
#include <mupdf/fitz.h>

#include "main_widget.h"

fz_context* mupdf_context = nullptr;
bool should_quit = false;

static std::mutex mupdf_mutexes[FZ_LOCK_MAX];

static void lock_mutex(void* user, int lock) {
    static_cast<std::mutex*>(user)[lock].lock();
}

static void unlock_mutex(void* user, int lock) {
    static_cast<std::mutex*>(user)[lock].unlock();
}

int main(int argc, char* argv[]) {
    QSurfaceFormat format;
    format.setVersion(3, 2);
    format.setProfile(QSurfaceFormat::CoreProfile);
    QSurfaceFormat::setDefaultFormat(format);

    QApplication app(argc, argv);
    app.setApplicationName("sioyek-core");

    fz_locks_context locks;
    locks.user    = mupdf_mutexes;
    locks.lock    = lock_mutex;
    locks.unlock  = unlock_mutex;

    mupdf_context = fz_new_context(nullptr, &locks, FZ_STORE_DEFAULT);
    if (!mupdf_context) {
        fprintf(stderr, "[core] could not create mupdf context\n");
        return 1;
    }
    // silence MuPDF's internal warnings (e.g. duplicate fz_icc_link in store)
    fz_set_warning_callback(mupdf_context, nullptr, nullptr);
    fz_set_error_callback(mupdf_context, nullptr, nullptr);
    fz_register_document_handlers(mupdf_context);

    MainWidget window;
    window.setWindowTitle("sioyek-core");
    window.show();

    if (argc >= 2) {
        std::wstring path = QString::fromUtf8(argv[1]).toStdWString();
        window.open_document(path);
    }

    int ret = app.exec();
    should_quit = true;

    fz_drop_context(mupdf_context);
    return ret;
}
