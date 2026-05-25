#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <qapplication.h>
#include <qsurfaceformat.h>
#include <mupdf/fitz.h>

#include "main_widget.h"
#include "pdf_view_opengl_widget.h"
#include "limn_build_info.h"
#include "limn_options.h"
#include "limn_bridge.h"
#include "limn_buffer_registry.h"
#include "limn_command.h"
#include "limn_input.h"
#include "limn_window_registry.h"

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
    // v0.37 A1c: --version dumps build provenance and exits.  Handled
    // first because it must work even without a display / socket / etc.
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--version") == 0) {
            std::fputs(limn_build_banner(), stdout);
            return 0;
        }
    }

    // Ignore SIGPIPE — Qt's QLocalSocket on macOS doesn't always set
    // SO_NOSIGPIPE, so writing to a peer-closed socket would otherwise
    // terminate the process.
    std::signal(SIGPIPE, SIG_IGN);

    // v0.37 A1c: print build banner to stderr at startup so every Limn
    // session — interactive, test, headless, container — surfaces its
    // own provenance.  Goes to stderr to keep stdout clean for any
    // tool piping Limn's wire output.
    std::fputs(limn_build_banner(), stderr);

    // Pre-scan argv for --headless so we can install the offscreen Qt
    // platform plugin BEFORE QApplication is constructed. The offscreen
    // platform still runs the full paint pipeline (so QWidget::grab() and
    // any paintEvent-driven invariants work) but never opens a visible
    // window — exactly what autonomous GUI testing needs.
    bool pre_headless = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--headless") == 0) { pre_headless = true; break; }
    }
    // For --headless: prefer the minimal platform. v0.22 §C found that
    // Qt 6.11's offscreen plugin aborts at QApplication construction on
    // the Linux container (silent SIGABRT, even with QT_DEBUG_PLUGINS).
    // minimal works for the bridge / wire-level tests that run under
    // --headless. Visual tests (test/text-widget-snapshot) live in OS-
    // tier which uses Xvfb + xcb, where widget->grab() works correctly.
    // Override via QT_QPA_PLATFORM=offscreen for paint-pipeline tests
    // once the offscreen plugin works again.
    if (pre_headless && std::getenv("QT_QPA_PLATFORM") == nullptr) {
        setenv("QT_QPA_PLATFORM", "minimal", 1);
    }

    // macOS: by default Qt swaps Ctrl/Cmd so that Qt::ControlModifier means
    // the Cmd key. That makes our "C-d" Emacs-style bindings fire on Cmd+D,
    // which is the OPPOSITE of what a user pressing literal "Ctrl-d"
    // expects. Turn the swap off so ControlModifier is always the physical
    // Ctrl key and MetaModifier is Cmd.
    QCoreApplication::setAttribute(Qt::AA_MacDontSwapCtrlAndMeta);

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
    // Always show(): under --headless we've switched to QT_QPA_PLATFORM=offscreen
    // so this paints into an offscreen surface (no visible window) but the full
    // layout + paintEvent pipeline runs — required for QWidget::grab() tests.
    window.resize(1200, 900);
    window.show();

    // ── Limn protocol layer ────────────────────────────────────────────
    LimnBufferRegistry  registry;
    LimnWindowRegistry  win_registry;
    LimnFrameRegistry   frame_registry;     // v0.18: f1 auto-registered in ctor
    LimnBridge          bridge(opts.effective_socket_path());
    LimnCommand         command(&bridge, &registry, &win_registry,
                                 &frame_registry, &window, opts);
    bridge.set_command_handler(&command);

    // v0.14: hand the opengl widget a back-pointer to LimnCommand so its
    // paintGL can read the focused window's overlays and record last
    // text-render metadata. Optional — widget no-ops if unset.
    if (window.opengl_widget()) {
        window.opengl_widget()->set_limn_command(&command);
    }

    // ── Input event capture (forwards Qt events as Limn events) ────────
    // Filter holds a back-pointer to LimnCommand so it can route printable
    // keystrokes through the minibuffer when one is open (SPEC §6).
    LimnInputFilter input_filter(&bridge, &command);
    app.installEventFilter(&input_filter);

    if (!opts.initial_path.isEmpty()) {
        window.open_document(opts.initial_path.toStdWString());
    }

    int ret = app.exec();
    should_quit = true;

    fz_drop_context(mupdf_context);
    return ret;
}
