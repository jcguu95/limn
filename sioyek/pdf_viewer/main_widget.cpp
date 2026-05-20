#include "main_widget.h"

#include <qboxlayout.h>
#include <qjsondocument.h>
#include <qjsonobject.h>
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
    // Set shader path to embedded Qt resource shaders
    shader_path = Path(L":/pdf_viewer/shaders");

    // Set up data directory for the database
    QString data_dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(data_dir);
    std::wstring local_db  = (data_dir + "/local.db").toStdWString();
    std::wstring global_db = (data_dir + "/shared.db").toStdWString();

    checksummer      = new CachedChecksummer({});
    db_manager       = new DatabaseManager();
    db_manager->open(local_db, global_db);
    db_manager->ensure_database_compatibility(local_db, global_db);
    // For a fresh DB, create_tables() already creates all columns; mark as current
    // version so the migration scripts don't try to add them again.
    if (db_manager->get_version() == 0) {
        db_manager->set_version();
    } else {
        db_manager->ensure_schema_compatibility();
    }
    document_manager = new DocumentManager(mupdf_context, db_manager, checksummer);
    document_view    = new DocumentView(db_manager, document_manager, checksummer);
    pdf_renderer     = new PdfRenderer(4, &should_quit, mupdf_context);
    pdf_renderer->start_threads();
    opengl_widget = new PdfViewOpenGLWidget(document_view, pdf_renderer, &stub_config, false, this);

    // When a background render thread finishes a tile, repaint immediately
    connect(pdf_renderer, &PdfRenderer::render_advance,
            opengl_widget, QOverload<>::of(&QWidget::update));
    setCentralWidget(opengl_widget);
    resize(1200, 900);
    setup_socket_server();
}

MainWidget::~MainWidget() {
    should_quit = true;
    pdf_renderer->join_threads();
    delete pdf_renderer;
    delete document_view;
    delete document_manager;
    delete db_manager;
    delete checksummer;
}

bool MainWidget::open_document(const std::wstring& path) {
    bool invalid = false;
    document_view->open_document(path, &invalid);
    opengl_widget->update();
    return !invalid;
}

void MainWidget::setup_socket_server() {
    socket_server = new QLocalServer(this);
    QLocalServer::removeServer("/tmp/sioyek-core");
    socket_server->listen("/tmp/sioyek-core");
    connect(socket_server, &QLocalServer::newConnection, this, [this]() {
        socket_client = socket_server->nextPendingConnection();
        connect(socket_client, &QLocalSocket::readyRead, this, &MainWidget::on_socket_data);
    });
}

void MainWidget::on_socket_data() {
    QByteArray data = socket_client->readAll();
    for (const QByteArray& line : data.split('\n')) {
        if (!line.trimmed().isEmpty()) dispatch_command(line.trimmed());
    }
}

void MainWidget::dispatch_command(const QByteArray& json) {
    QJsonDocument doc = QJsonDocument::fromJson(json);
    if (!doc.isObject()) return;
    QJsonObject obj = doc.object();
    QString cmd = obj["cmd"].toString();

    if (cmd == "scroll") {
        float dy = obj["dy"].toDouble(0);
        document_view->move_absolute(0, dy);
        opengl_widget->update();
    } else if (cmd == "zoom") {
        float level = obj["level"].toDouble(1.0);
        document_view->set_zoom_level(level, true);
        opengl_widget->update();
    } else if (cmd == "goto-page") {
        int page = obj["page"].toInt(0);
        document_view->goto_page(page);
        opengl_widget->update();
    } else if (cmd == "dark-mode") {
        bool on = obj["on"].toBool(true);
        opengl_widget->set_dark_mode(on);
        opengl_widget->update();
    } else if (cmd == "open") {
        std::wstring path = obj["path"].toString().toStdWString();
        open_document(path);
    }
}
