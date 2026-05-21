#include <csignal>
#include <mutex>
#include <qapplication.h>
#include <qsurfaceformat.h>
#include <mupdf/fitz.h>

#include "main_widget.h"
#include "limn_options.h"
#include "limn_bridge.h"
#include "limn_buffer_registry.h"
#include "limn_command.h"
#include "limn_input.h"

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
    // Ignore SIGPIPE — Qt's QLocalSocket on macOS doesn't always set
    // SO_NOSIGPIPE, so writing to a peer-closed socket would otherwise
    // terminate the process.
    std::signal(SIGPIPE, SIG_IGN);

    QSurfaceFormat format;
    format.setVersion(3, 2);
    format.setProfile(QSurfaceFormat::CoreProfile);
    QSurfaceFormat::setDefaultFormat(format);

    QApplication app(argc, argv);
    app.setApplicationName("limn");

    const LimnOptions opts = LimnOptions::parse(app.arguments());

    fz_locks_context locks;
    locks.user    = mupdf_mutexes;
    locks.lock    = lock_mutex;
    locks.unlock  = unlock_mutex;

    mupdf_context = fz_new_context(nullptr, &locks, FZ_STORE_DEFAULT);
    if (!mupdf_context) {
        fprintf(stderr, "[limn] could not create mupdf context\n");
        return 1;
    }
    fz_set_warning_callback(mupdf_context, nullptr, nullptr);
    fz_set_error_callback(mupdf_context, nullptr, nullptr);
    fz_register_document_handlers(mupdf_context);

    MainWidget window;
    window.setWindowTitle("limn");
    if (!opts.headless) window.show();

    // ── Limn protocol layer ────────────────────────────────────────────
    LimnBufferRegistry registry;
    LimnBridge         bridge(opts.effective_socket_path());
    LimnCommand        command(&bridge, &registry, &window, opts);
    bridge.set_command_handler(&command);

    // ── Input event capture (forwards Qt events as Limn events) ────────
    LimnInputFilter input_filter(&bridge);
    app.installEventFilter(&input_filter);

    if (!opts.initial_path.isEmpty()) {
        window.open_document(opts.initial_path.toStdWString());
    }

    int ret = app.exec();
    should_quit = true;

    fz_drop_context(mupdf_context);
    return ret;
}
