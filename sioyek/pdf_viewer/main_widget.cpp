#include "main_widget.h"

#include <qboxlayout.h>
#include <qstandardpaths.h>
#include <qdir.h>
#include <QSplitter>
#include <QStackedWidget>
#include <QPlainTextEdit>
#include <QFont>
#include <QTextOption>

#include "document.h"
#include "document_view.h"
#include "pdf_renderer.h"
#include "pdf_view_opengl_widget.h"
#include "database.h"
#include "checksum.h"
#include "limn_chrome_bar.h"
#include "config.h"
#include "path.h"

extern fz_context* mupdf_context;
extern bool should_quit;
extern Path shader_path;

static ConfigManager stub_config;

MainWidget::MainWidget(QWidget* parent) : QMainWindow(parent) {
    shader_path = Path(L":/pdf_viewer/shaders");

    QString data_dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(data_dir);
    std::wstring local_db  = (data_dir + "/local.db").toStdWString();
    std::wstring global_db = (data_dir + "/shared.db").toStdWString();

    checksummer_      = new CachedChecksummer({});
    db_manager_       = new DatabaseManager();
    db_manager_->open(local_db, global_db);
    db_manager_->ensure_database_compatibility(local_db, global_db);
    if (db_manager_->get_version() == 0) {
        db_manager_->set_version();
    } else {
        db_manager_->ensure_schema_compatibility();
    }
    document_manager_ = new DocumentManager(mupdf_context, db_manager_, checksummer_);
    document_view_    = new DocumentView(db_manager_, document_manager_, checksummer_);
    pdf_renderer_     = new PdfRenderer(4, &should_quit, mupdf_context);
    pdf_renderer_->start_threads();
    opengl_widget_    = new PdfViewOpenGLWidget(document_view_, pdf_renderer_, &stub_config, false, this);

    connect(pdf_renderer_, &PdfRenderer::render_advance,
            opengl_widget_, QOverload<>::of(&QWidget::update));

    // ── Limn chrome (SPEC §1.2 / §5.4–§5.6) + viewport splitter ─────
    // Central widget layout:
    //   [ viewport_splitter (Horizontal, holds N OpenGL viewports) ] ← stretches
    //   [ chrome_bar         (fixed height)                          ]
    //
    // bridge/win-split adds a new viewport widget into viewport_splitter_
    // (SPEC v0.5 §5.1 — real visible split). v0.8 shares DocumentView
    // across panes — independent per-window state is v0.9 work.
    chrome_bar_       = new LimnChromeBar(this);
    viewport_splitter_= new QSplitter(Qt::Horizontal, this);
    viewport_splitter_->setChildrenCollapsible(false);

    // SPEC v0.22 §C — wrap opengl_widget in QStackedWidget so we can
    // switch between PDF view (index 0) and text-engine view (index 1).
    //
    // text_widget_ is read-only display-only: input always flows through
    // the app-level LimnInputFilter (limn_input.cpp) → bridge → Lisp
    // text-mode → buffer/insert. The widget mirrors the buffer state;
    // it's not the source of truth. Setting NoFocus prevents Qt from
    // routing key events to it (they bubble up to the input filter).
    //
    // Font is set explicitly to Noto Sans (with sans-serif fallback)
    // to avoid tofu boxes on CJK / Unicode glyphs that the system
    // default font may not cover. Dockerfile installs fonts-noto-cjk.
    main_stack_       = new QStackedWidget(this);
    main_stack_->addWidget(opengl_widget_);     // index 0 — PDF
    text_widget_      = new QPlainTextEdit(this);
    text_widget_->setReadOnly(true);
    text_widget_->setFocusPolicy(Qt::NoFocus);
    // SPEC v0.22 §C — font setup deferred (see fontconfig issue note).
    // QFont("Noto Sans") triggers fontconfig init which crashes the
    // process in Docker container (no /etc/fonts setup). The default
    // sans-serif font handles ASCII fine; CJK glyph coverage needs
    // fontconfig fix (see CHANGELOG / Dockerfile).
    text_widget_->setWordWrapMode(QTextOption::WrapAtWordBoundaryOrAnywhere);
    text_widget_->setLineWrapMode(QPlainTextEdit::WidgetWidth);
    main_stack_->addWidget(text_widget_);       // index 1 — text engine
    main_stack_->setCurrentIndex(0);
    viewport_splitter_->addWidget(main_stack_);

    auto* central  = new QWidget(this);
    auto* layout   = new QVBoxLayout(central);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    layout->addWidget(viewport_splitter_, 1);  // stretch=1, gets all height
    layout->addWidget(chrome_bar_, 0);
    setCentralWidget(central);
    resize(1200, 900);
}

void MainWidget::show_text_view() {
    if (main_stack_) main_stack_->setCurrentIndex(1);
}

void MainWidget::show_pdf_view() {
    if (main_stack_) main_stack_->setCurrentIndex(0);
}

// Phase 2 — see docs/split-frame-design.md. Today every LimnWindow maps
// to the single document_view_; the overload exists so LimnCommand can
// be migrated to a win-aware API without behaviour change. When Phase 3
// (per-win DVs) lands, this becomes panes_[win_id].dv (and the no-arg
// document_view() becomes panes_[focused_id].dv). Empty win_id falls
// back to the focused/singleton DV — that's how non-per-win callers
// (singleton load paths, helper sites) keep working unchanged.
DocumentView* MainWidget::document_view(const QString& /*win_id*/) {
    return document_view_;
}

// markup-interaction step 2 — side-panel layout.
//
// The text view normally lives at index 1 of main_stack_ and is shown
// full-screen by flipping the stack (show_text_view), which hides the
// PDF. For the M-N annotation list we instead want the list on the LEFT
// (~1/3) with the PDF still visible on the RIGHT (~2/3). We achieve that
// by reparenting text_widget_ out of main_stack_ and inserting it as the
// first pane of viewport_splitter_, then forcing main_stack_ back to the
// PDF (index 0) so the right pane renders the page.
void MainWidget::enter_text_panel(double ratio) {
    if (text_panel_mode_ || !viewport_splitter_ || !main_stack_ || !text_widget_)
        return;
    // Pull text_widget_ out of the stack (removeWidget detaches without
    // deleting; the widget keeps main_stack_ as parent until re-parented).
    main_stack_->removeWidget(text_widget_);
    viewport_splitter_->setOrientation(Qt::Horizontal);
    viewport_splitter_->insertWidget(0, text_widget_);   // left pane
    text_widget_->show();
    main_stack_->setCurrentIndex(0);                     // PDF in right pane
    // Size the panes ~ratio : (1-ratio).
    const int total = qMax(1, viewport_splitter_->width());
    const int left  = qBound(120, int(total * ratio), total - 120);
    QList<int> sizes;
    sizes << left << (total - left);
    viewport_splitter_->setSizes(sizes);
    text_panel_mode_ = true;
}

void MainWidget::exit_text_panel() {
    if (!text_panel_mode_ || !main_stack_ || !text_widget_) return;
    // Bug-Set-B #3 — clear any focus-border stylesheets applied by
    // chrome/focus-pane so they don't linger on the full-screen PDF or the
    // next time the text widget is shown.
    text_widget_->setStyleSheet(QString());
    main_stack_->setStyleSheet(QString());
    // Move text_widget_ back into the stack at index 1 (addWidget reparents).
    text_widget_->hide();
    main_stack_->addWidget(text_widget_);
    main_stack_->setCurrentIndex(0);                     // PDF full-screen
    text_panel_mode_ = false;
}

PdfViewOpenGLWidget* MainWidget::add_split_pane(const QString& orientation) {
    if (!viewport_splitter_) return nullptr;
    // Adjust splitter orientation. v0.8 keeps it simple: each call sets
    // the orientation; mixing h/v needs nested splitters and is left for
    // v0.9 (along with proper per-window state).
    viewport_splitter_->setOrientation(
        orientation == "v" ? Qt::Vertical : Qt::Horizontal);

    // Build a new PdfViewOpenGLWidget sharing DocumentView + PdfRenderer.
    // Shared DV means scrolling one pane affects the other — caveat
    // documented; v0.9 will give each pane its own DocumentView.
    // Reuses the module-static stub_config defined at file top — same
    // ConfigManager that the original opengl_widget_ uses.
    auto* pane = new PdfViewOpenGLWidget(document_view_, pdf_renderer_,
                                          &stub_config, false, this);
    connect(pdf_renderer_, &PdfRenderer::render_advance,
            pane, QOverload<>::of(&QWidget::update));
    viewport_splitter_->addWidget(pane);
    return pane;
}

int MainWidget::viewport_count() const {
    return viewport_splitter_ ? viewport_splitter_->count() : 0;
}

MainWidget::~MainWidget() {
    should_quit = true;
    pdf_renderer_->join_threads();
    delete pdf_renderer_;
    delete document_view_;
    delete document_manager_;
    delete db_manager_;
    delete checksummer_;
}

bool MainWidget::open_document(const std::wstring& path) {
    // v0.39 B6 — pass nullptr instead of `&local_bool`.  Pre-v0.39 we
    // declared `bool invalid = false` here and passed `&invalid` down
    // into Document::open's chain, which stores that pointer into
    // `Document::invalid_flag_pointer` and then captures it into two
    // DETACHED background threads (load_page_dimensions + index_document).
    // Those threads write `*invalid_flag_pointer = true` AFTER this
    // function has already returned and its stack slot has been reused
    // by some other call frame — a textbook stack-use-after-return that
    // ASAN flagged at document.cpp:1160 (`if (invalid_flag_pointer)
    // *invalid_flag_pointer = true`).  In production the corruption
    // landed wherever the stack happened to be, manifesting as ~30%
    // "*** stack smashing detected ***" on PDF-load workflows (W10
    // "set bookmark then jump" being the most reliable trigger).
    //
    // The `invalid` flag's documented purpose is to signal "view needs
    // a refresh once async caches finish".  MainWidget never observed
    // that signal — the only read was the `if (invalid || !doc)` check
    // immediately below, which fires synchronously before the detached
    // threads ever run, so `invalid` was guaranteed false at the read
    // and the check collapsed to `!doc`.  Passing nullptr makes both
    // detached threads no-op via the existing `if (invalid_flag_pointer)`
    // null guards (document.cpp:1143, 1159, 1177).
    //
    // Failure detection still works: document_view_->open_document sets
    // current_document = nullptr on open failure (document_view.cpp:792),
    // so get_document() == nullptr remains the canonical "open failed"
    // signal — which we already checked, and now is the sole check.
    document_view_->open_document(path, nullptr);
    // sioyek's invalid_flag isn't reliable for "file does not exist". The
    // ground truth is whether DocumentView ended up with a non-null Document.
    Document* doc = document_view_->get_document();
    if (!doc) {
        return false;
    }
    // In headless / pre-layout state, the OpenGL widget hasn't sized
    // itself yet, so sioyek's auto-resize zoom doesn't fire. Force a
    // sensible default so view/get returns a positive zoom.
    if (document_view_->get_zoom_level() <= 0.0f) {
        document_view_->set_zoom_level(1.0f, true);
    }
    opengl_widget_->update();
    return true;
}
