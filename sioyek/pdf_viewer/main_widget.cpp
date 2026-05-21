#include "main_widget.h"

#include <qboxlayout.h>
#include <qstandardpaths.h>
#include <qdir.h>

#include "document.h"
#include "document_view.h"
#include "pdf_renderer.h"
#include "pdf_view_opengl_widget.h"
#include "database.h"
#include "checksum.h"
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
    setCentralWidget(opengl_widget_);
    resize(1200, 900);
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
    bool invalid = false;
    document_view_->open_document(path, &invalid);
    if (!invalid) {
        // In headless / pre-layout state, the OpenGL widget hasn't sized
        // itself yet, so sioyek's auto-resize zoom doesn't fire. Force a
        // sensible default so view/get returns a positive zoom.
        if (document_view_->get_zoom_level() <= 0.0f) {
            document_view_->set_zoom_level(1.0f, true);
        }
    }
    opengl_widget_->update();
    return !invalid;
}
